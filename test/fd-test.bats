load test_helper

@test "blocking debug" {
  echo "SHELL_FLAG=$SHELL_FLAG"
  echo "SHELL=$SHELL"
  run timeout 15 "$ZMX" run test-blocking $SHELL_FLAG echo hello
  echo "STATUS: $status"
  echo "OUTPUT: $output"
  false
}
