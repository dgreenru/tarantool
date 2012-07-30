/*
 * Copyright (C) 2011 Mail.RU
 * Copyright (C) 2011 Yuriy Vostrikov
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY AUTHOR AND CONTRIBUTORS ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL AUTHOR OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */
#include <replication.h>
#include <net_io.h>
#include <say.h>
#include <fiber.h>
#include TARANTOOL_CONFIG
#include <palloc.h>
#include <stddef.h>
#include <sock.h>

#include <stddef.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <sys/uio.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <limits.h>
#include <fcntl.h>

#include "fiber.h"
#include "recovery.h"
#include "log_io.h"

/** Replication topology
 * ----------------------
 *
 * Tarantool replication consists of 3 interacting processes:
 * master, spawner and replication relay.
 *
 * The spawner is created at server start, and master communicates
 * with the spawner using a socketpair(2). Replication relays are
 * created by the spawner and handle one client connection each.
 *
 * The master process binds to replication_port and accepts
 * incoming connections. This is done in the master to be able to
 * correctly handle RELOAD CONFIGURATION, which happens in the
 * master, and, in future, perform authentication of replication
 * clients.
 *
 * Once a client socket is accepted, it is sent to the spawner
 * process, through the master's end of the socket pair.
 *
 * The spawner listens on the receiving end of the socket pair and
 * for every received socket creates a replication relay, which is
 * then responsible for sending write ahead logs to the replica.
 *
 * Upon shutdown, the master closes its end of the socket pair.
 * The spawner then reads EOF from its end, terminates all
 * children and exits.
 */
static int master_to_spawner_sock;
static int replication_relay_sock;

/** Replication spawner process */
static struct spawner {
	/** reading end of the socket pair with the master */
	int sock;
	/** non-zero if got a terminating signal */
	sig_atomic_t killed;
	/** child process count */
	sig_atomic_t child_count;
} spawner;

/** Initialize spawner process.
 *
 * @param sock the socket between the main process and the spawner.
 */
static void
spawner_init(int sock);

/** Spawner main loop. */
static void
spawner_main_loop();

/** Shutdown spawner and all its children. */
static void
spawner_shutdown();

/** Handle SIGINT, SIGTERM, SIGPIPE, SIGHUP. */
static void
spawner_signal_handler(int signal);

/** Handle SIGCHLD: collect status of a terminated child.  */
static void
spawner_sigchld_handler(int signal __attribute__((unused)));

/** Create a replication relay.
 *
 * @return 0 on success, -1 on error
 */
static int
spawner_create_replication_relay(int client_sock);

/** Shut down all relays when shutting down the spawner. */
static void
spawner_shutdown_children();

/** Initialize replication relay process. */
static void
replication_relay_loop(int client_sock);

/** A libev callback invoked when a relay client socket is ready
 * for read. This currently only happens when the client closes
 * its socket, and we get an EOF.
 */
static void
replication_relay_recv(struct ev_io *w, int revents);

/** Send a single row to the client. */
static int
replication_relay_send_row(struct tbuf *t);


/*
 * ------------------------------------------------------------------------
 * replication module
 * ------------------------------------------------------------------------
 */

@interface ReplicaAcceptor: Acceptor {
	int replica_sock;
	ev_io send_event;
}
- (void) onOutput;
@end

@implementation ReplicaAcceptor

static void
output_cb(ev_watcher *watcher, int revents __attribute__((unused)))
{
	ReplicaAcceptor *acceptor = watcher->data;
	[acceptor onOutput];
}

- (id) init: (struct service_config *)config
{
	self = [super init: config];
	if (self) {
		replica_sock = -1;
		send_event.data = self;
		ev_init(&send_event, (void *) output_cb);
		ev_io_set(&send_event, master_to_spawner_sock, EV_WRITE);
	}
	return self;
}

/** Send the file descriptor to replication relay spawner.
 */
- (bool) send
{
	struct msghdr msg;
	struct iovec iov[1];
	char control_buf[CMSG_SPACE(sizeof(int))];
	struct cmsghdr *control_message = NULL;
	int cmd_code = 0;

	iov[0].iov_base = &cmd_code;
	iov[0].iov_len = sizeof(cmd_code);

	memset(&msg, 0, sizeof(msg));

	msg.msg_name = NULL;
	msg.msg_namelen = 0;
	msg.msg_iov = iov;
	msg.msg_iovlen = 1;
	msg.msg_control = control_buf;
	msg.msg_controllen = sizeof(control_buf);

	control_message = CMSG_FIRSTHDR(&msg);
	control_message->cmsg_len = CMSG_LEN(sizeof(int));
	control_message->cmsg_level = SOL_SOCKET;
	control_message->cmsg_type = SCM_RIGHTS;
	*((int *) CMSG_DATA(control_message)) = replica_sock;

	/* send client socket to the spawner */
	int sent = sendmsg(master_to_spawner_sock, &msg, 0);
	if (sent < 0) {
		if (errno == EAGAIN || errno == EWOULDBLOCK) {
			return false;
		}
		say_syserror("sendmsg");
	}

	close(replica_sock);
	return true;
}

- (void) onAccept: (int)fd :(struct sockaddr_in *)addr
{
	assert(replica_sock == -1);

	say_info("connection from %s:%d",
		 inet_ntoa(addr->sin_addr),
		 ntohs(addr->sin_port));

	sock_set_option_nc(fd, SOL_SOCKET, SO_KEEPALIVE);
	sock_set_blocking(fd, false);

	ev_io_stop(&accept_event);
	ev_io_start(&send_event);

	replica_sock = fd;
}

- (void) onOutput
{
	assert(replica_sock >= 0);

	if (![self send]) {
		return;
	}

	ev_io_start(&accept_event);
	ev_io_stop(&send_event);

	replica_sock = -1;
}

@end

static ReplicaAcceptor *replica_acceptor;

/** Check replication module configuration. */
int
replication_check_config(struct tarantool_cfg *config)
{
	if (config->replication_port < 0 ||
	    config->replication_port >= USHRT_MAX) {
		say_error("invalid replication port value: %"PRId32,
			  config->replication_port);
		return -1;
	}

	return 0;
}

/** Pre-fork replication spawner process. */
void
replication_prefork()
{
	if (cfg.replication_port == 0) {
		/* replication is not needed, do nothing */
		return;
	}
	int sockpair[2];
	/*
	 * Create UNIX sockets to communicate between the main and
	 * spawner processes.
         */
	if (socketpair(PF_LOCAL, SOCK_STREAM, 0, sockpair) != 0)
		panic_syserror("socketpair");

	/* create spawner */
	pid_t pid = fork();
	if (pid == -1)
		panic_syserror("fork");

	if (pid != 0) {
		/* parent process: tarantool */
		close(sockpair[1]);
		master_to_spawner_sock = sockpair[0];
		if (set_nonblock(master_to_spawner_sock) == -1)
			panic("set_nonblock");
	} else {
		ev_default_fork();
		ev_loop(EVLOOP_NONBLOCK);
		/* child process: spawner */
		close(sockpair[0]);
		/*
		 * Move to an own process group, to not receive
		 * signals from the controlling tty.
		 */
		setpgid(0, 0);
		spawner_init(sockpair[1]);
	}
}

/**
 * Create a fiber which accepts client connections and pushes them
 * to replication spawner.
 */

void
replication_init()
{
	if (cfg.replication_port == 0)
		return;                        /* replication is not in use */

	struct service_config config;
	tarantool_config_service(&config, cfg.replication_port);

	replica_acceptor = [ReplicaAcceptor alloc];
	[replica_acceptor init: &config];
	[replica_acceptor start];
}

/*-----------------------------------------------------------------------------*/
/* spawner process                                                             */
/*-----------------------------------------------------------------------------*/

/** Initialize the spawner. */

static void
spawner_init(int sock)
{
	char name[sizeof(fiber->name)];
	struct sigaction sa;

	snprintf(name, sizeof(name), "spawner%s", custom_proc_title);
	fiber_set_name(fiber, name);
	set_proc_title(name);

	/* init replicator process context */
	spawner.sock = sock;

	/* init signals */
	memset(&sa, 0, sizeof(sa));
	sigemptyset(&sa.sa_mask);

	/*
	 * The spawner normally does not receive any signals,
	 * except when sent by a system administrator.
	 * When the master process terminates, it closes its end
	 * of the socket pair and this signals to the spawner that
	 * it's time to die as well. But before exiting, the
	 * spawner must kill and collect all active replication
	 * relays. This is why we need to change the default
	 * signal action here.
	 */
	sa.sa_handler = spawner_signal_handler;

	if (sigaction(SIGHUP, &sa, NULL) == -1 ||
	    sigaction(SIGINT, &sa, NULL) == -1 ||
	    sigaction(SIGTERM, &sa, NULL) == -1 ||
	    sigaction(SIGPIPE, &sa, NULL) == -1)
		say_syserror("sigaction");

	sa.sa_handler = spawner_sigchld_handler;

	if (sigaction(SIGCHLD, &sa, NULL) == -1)
		say_syserror("sigaction");

	say_crit("initialized");
	spawner_main_loop();
}



static int
spawner_unpack_cmsg(struct msghdr *msg)
{
	struct cmsghdr *control_message;
	for (control_message = CMSG_FIRSTHDR(msg);
	     control_message != NULL;
	     control_message = CMSG_NXTHDR(msg, control_message))
		if ((control_message->cmsg_level == SOL_SOCKET) &&
		    (control_message->cmsg_type == SCM_RIGHTS))
			return *((int *) CMSG_DATA(control_message));
	assert(false);
	return -1;
}

/** Replication spawner process main loop. */
static void
spawner_main_loop()
{
	struct msghdr msg;
	struct iovec iov[1];
	char control_buf[CMSG_SPACE(sizeof(int))];
	int cmd_code = 0;
	int client_sock;

	iov[0].iov_base = &cmd_code;
	iov[0].iov_len = sizeof(cmd_code);

	msg.msg_name = NULL;
	msg.msg_namelen = 0;
	msg.msg_iov = iov;
	msg.msg_iovlen = 1;
	msg.msg_control = control_buf;
	msg.msg_controllen = sizeof(control_buf);

	while (!spawner.killed) {
		int msglen = recvmsg(spawner.sock, &msg, 0);
		if (msglen > 0) {
			client_sock = spawner_unpack_cmsg(&msg);
			spawner_create_replication_relay(client_sock);
		} else if (msglen == 0) { /* orderly master shutdown */
			say_info("Exiting: master shutdown");
			break;
		} else { /* msglen == -1 */
			if (errno != EINTR)
				say_syserror("recvmsg");
			/* continue, the error may be temporary */
		}
	}
	spawner_shutdown();
}

/** Replication spawner shutdown. */
static void
spawner_shutdown()
{
	/* close socket */
	close(spawner.sock);

	/* kill all children */
	spawner_shutdown_children();

	exit(EXIT_SUCCESS);
}

/** Replication spawner signal handler for terminating signals. */
static void spawner_signal_handler(int signal)
{
	spawner.killed = signal;
}

/** Wait for a terminated child. */
static void
spawner_sigchld_handler(int signo __attribute__((unused)))
{
	static const char waitpid_failed[] = "spawner: waitpid() failed\n";
	do {
		int exit_status;
		pid_t pid = waitpid(-1, &exit_status, WNOHANG);
		switch (pid) {
		case -1:
			if (errno != ECHILD) {
				int r = write(sayfd, waitpid_failed,
					      sizeof(waitpid_failed) - 1);
				(void) r; /* -Wunused-result warning suppression */
			}
			return;
		case 0: /* no more changes in children status */
			return;
		default:
			spawner.child_count--;
		}
	} while (spawner.child_count > 0);
}

/** Create replication client handler process. */
static int
spawner_create_replication_relay(int client_sock)
{
	pid_t pid = fork();

	if (pid < 0) {
		say_syserror("fork");
		return -1;
	}

	if (pid == 0) {
		ev_default_fork();
		ev_loop(EVLOOP_NONBLOCK);
		close(spawner.sock);
		replication_relay_loop(client_sock);
	} else {
		spawner.child_count++;
		close(client_sock);
		say_info("created a replication relay: pid = %d", (int) pid);
	}

	return 0;
}

/** Replicator spawner shutdown: kill and wait for children. */
static void
spawner_shutdown_children()
{
	int kill_signo = SIGTERM, signo;
	sigset_t mask, orig_mask, alarm_mask;

retry:
	sigemptyset(&mask);
	sigaddset(&mask, SIGCHLD);
	sigaddset(&mask, SIGALRM);
	/*
	 * We're going to kill the entire process group, which
	 * we're part of. Handle the signal sent to ourselves.
	 */
	sigaddset(&mask, kill_signo);

	if (spawner.child_count == 0)
		return;

	/* Block SIGCHLD and SIGALRM to avoid races. */
	if (sigprocmask(SIG_BLOCK, &mask, &orig_mask)) {
		say_syserror("sigprocmask");
		return;
	}

	/* We'll wait for children no longer than 5 sec.  */
	alarm(5);

	say_info("sending signal %d to %"PRIu32" children", kill_signo,
		 (u32) spawner.child_count);

	kill(0, kill_signo);

	say_info("waiting for children for up to 5 seconds");

	while (spawner.child_count > 0) {
		sigwait(&mask, &signo);
		if (signo == SIGALRM) {         /* timed out */
			break;
		}
		else if (signo != kill_signo) {
			assert(signo == SIGCHLD);
			spawner_sigchld_handler(signo);
		}
	}

	/* Reset the alarm. */
	alarm(0);

	/* Clear possibly pending SIGALRM. */
	sigpending(&alarm_mask);
	if (sigismember(&alarm_mask, SIGALRM)) {
		sigemptyset(&alarm_mask);
		sigaddset(&alarm_mask, SIGALRM);
		sigwait(&alarm_mask, &signo);
	}

	/* Restore the old mask. */
	if (sigprocmask(SIG_SETMASK, &orig_mask, NULL)) {
		say_syserror("sigprocmask");
		return;
	}

	if (kill_signo == SIGTERM) {
		kill_signo = SIGKILL;
		goto retry;
	}
}

/** The main loop of replication client service process. */
static void
replication_relay_loop(int client_sock)
{
	struct sigaction sa;
	struct tbuf *ver;
	i64 lsn;
	ssize_t r;

	/* Initialize global. */
	replication_relay_sock = client_sock;

	/* set process title and fiber name */
	struct sockaddr_in peer;
	socklen_t addrlen = sizeof(peer);
	if (sock_peer_name(client_sock, &peer, &addrlen) == 0) {
		char pname[FIBER_NAME_MAXLEN];
		char fname[FIBER_NAME_MAXLEN];
		sock_address_string(&peer, pname, sizeof(pname));
		snprintf(fname, sizeof(fname), "relay/%s", pname);
		fiber_set_name(fiber, fname);
		set_proc_title("%s%s", fname, custom_proc_title);
	}

	/* init signals */
	memset(&sa, 0, sizeof(sa));
	sigemptyset(&sa.sa_mask);

	/* Reset all signals to their defaults. */
	sa.sa_handler = SIG_DFL;
	if (sigaction(SIGCHLD, &sa, NULL) == -1 ||
	    sigaction(SIGHUP, &sa, NULL) == -1 ||
	    sigaction(SIGINT, &sa, NULL) == -1 ||
	    sigaction(SIGTERM, &sa, NULL) == -1)
		say_syserror("sigaction");

	/* Block SIGPIPE, we already handle EPIPE. */
	sa.sa_handler = SIG_IGN;
	if (sigaction(SIGPIPE, &sa, NULL) == -1)
		say_syserror("sigaction");

	r = read(client_sock, &lsn, sizeof(lsn));
	if (r != sizeof(lsn)) {
		if (r < 0) {
			panic_syserror("read");
		}
		panic("invalid LSN request size: %zu", r);
	}
	say_info("starting replication from lsn: %"PRIi64, lsn);

	ver = tbuf_alloc(fiber->gc_pool);
	tbuf_append(ver, &default_version, sizeof(default_version));
	replication_relay_send_row(ver);

	/* init libev events handlers */
	ev_default_loop(0);

	/* init read events */
	struct ev_io sock_read_ev;
	ev_io_init(&sock_read_ev, replication_relay_recv, client_sock, EV_READ);
	ev_io_start(&sock_read_ev);

	/* Initialize the recovery process */
	recovery_init(cfg.snap_dir, cfg.wal_dir, replication_relay_send_row,
		      INT32_MAX, "fsync_delay", 0,
		      RECOVER_READONLY);
	/*
	 * Note that recovery starts with lsn _NEXT_ to
	 * the confirmed one.
	 */
	recovery_state->lsn = recovery_state->confirmed_lsn = lsn - 1;
	recover_existing_wals(recovery_state);
	/* Found nothing. */
	if (recovery_state->lsn == lsn - 1)
		say_error("can't find WAL containing record with lsn: %" PRIi64, lsn);
	recovery_follow_local(recovery_state, 0.1);

	ev_loop(0);

	say_crit("exiting the relay loop");
	exit(EXIT_SUCCESS);
}

/** Receive data event to replication socket handler */
static void
replication_relay_recv(struct ev_io *w __attribute__((unused)),
		       int __attribute__((unused)) revents)
{
	u8 data;

	int result = recv(replication_relay_sock, &data, sizeof(data), 0);
	if (result == 0 || (result < 0 && errno == ECONNRESET)) {
		say_info("the client has closed its replication socket, exiting");
		exit(EXIT_SUCCESS);
	}
	if (result < 0)
		say_syserror("recv");

	exit(EXIT_FAILURE);
}

/** Send to row to client. */
static int
replication_relay_send_row(struct tbuf *t)
{
	u8 *data = t->data;
	ssize_t bytes, len = t->size;
	while (len > 0) {
		bytes = write(replication_relay_sock, data, len);
		if (bytes < 0) {
			if (errno == EPIPE) {
				/* socket closed on opposite site */
				goto shutdown_handler;
			}
			panic_syserror("write");
		}
		len -= bytes;
		data += bytes;
	}

	say_debug("send row: %" PRIu32 " bytes %s", t->size, tbuf_to_hex(t));
	return 0;
shutdown_handler:
	say_info("the client has closed its replication socket, exiting");
	exit(EXIT_SUCCESS);
}

