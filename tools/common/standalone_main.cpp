// One built-in tool as its own program, without Qt, for a board with no interpreter and no GUI (tools/build-standalone.sh):
//   c++ -std=c++17 -O2 -DTOOL_MAIN=pr_partial_main tools/common/standalone_main.cpp tools/pr_partial/pr_partial.cpp -o pr-partial
int TOOL_MAIN(int argc, char** argv);
int main(int argc, char** argv) { return TOOL_MAIN(argc, argv); }
