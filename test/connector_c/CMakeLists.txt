include_directories("${PROJECT_SOURCE_DIR}/test/unit")
tarantool_client("tt" tt.c)
tarantool_client("update" update.c)
tarantool_client("xlog" xlog.c)
tarantool_client("rpl" rpl.c)
tarantool_client("snap" snap.c)
