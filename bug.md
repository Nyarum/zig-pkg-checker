debug(tardy/runtime): 0 - processing index=4
debug(tardy/runtime): 0 - running index=4
debug(build_system): Starting async build task for package 18 with Zig 0.14.0
debug(build_system): Executing core Docker build for package 18, Zig 0.14.0 (no Runtime)
info(build_system): Executing Docker build for zxcasd2q3123 with Zig 0.14.0 (build_id: 18-0.14.0-1748093554)
debug(build_system): Executing docker command: docker run --rm --name build-18-0.14.0-1748093554 -e REPO_URL=https://github.com/tardy-org/tardy -e PACKAGE_NAME=zxcasd2q3123 -e BUILD_ID=18-0.14.0-1748093554 -e RESULT_FILE=/results/build_result_18-0.14.0-1748093554.json -v /tmp/zig_pkg_checker_results:/results --memory=2g --cpus=2 zig-checker:0.14.0
info(build_system): Docker container completed successfully for build 18-0.14.0-1748093554
debug(build_system): Processing build result file: /tmp/zig_pkg_checker_results/build_result_18-0.14.0-1748093554.json for package 18, Zig 0.14.0
debug(build_system): Build result file content length: 331 bytes
debug(build_system): Processing JSON content: {
  "build_id": "18-0.14.0-1748093554",
  "package_name": "zxcasd2q3123",
  "repo_url": "https://github.com/tardy-org/tardy",
  "zig_version": "0.14.0",
  "start_time": "2025-05-24T13:32:34Z",
  "build_status": "success",
  "test_status": "success",
  "error_log": "\n",
  "build_log": "\n",
  "end_time": "2025-05-24T13:32:46Z"
}

debug(build_system): Parsed JSON - build_status: success, test_status: success, error_log: '' (length: 0)
debug(build_system): Updating build result for package 18 with Zig 0.14.0: status=success, test_status=success
Process 30341 stopped
* thread #1, queue = 'com.apple.main-thread', stop reason = EXC_BAD_ACCESS (code=1, address=0x1022688b8)
    frame #0: 0x000000010032ab50 zig_pkg_checker`yy_reduce(yypParser=0x000000010227c568, yyruleno=406, yyLookahead=130, yyLookaheadToken=(z = "UPDATE build_results SET build_status = :build_status, test_status = :test_status, error_log = :error_log, last_checked = CURRENT_TIMESTAMP WHERE package_id = :package_id AND zig_version = :zig_version", n = 6), pParse=0x000000010227d4d0) at sqlite3.c:179436:26
   179433       /********** End reduce actions ************************************************/
   179434         };
   179435         assert( yyruleno<sizeof(yyRuleInfoLhs)/sizeof(yyRuleInfoLhs[0]) );
-> 179436         yygoto = yyRuleInfoLhs[yyruleno];
   179437         yysize = yyRuleInfoNRhs[yyruleno];
   179438         yyact = yy_find_reduce_action(yymsp[yysize].stateno,(YYCODETYPE)yygoto);
   179439
Target 0: (zig_pkg_checker) stopped.
(lldb) ^C