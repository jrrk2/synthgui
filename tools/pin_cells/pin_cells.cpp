// pin_cells -- xc7/pin_cells.py in C++: give cells BEL attributes (the test MMCM on a right-column CMT, the ICAPE2 on the top
// ICAP site).  The file is rewritten as json.dump(indent=1) does, byte for byte; tools/pr_partial/compare.sh checks that.
//
//   synthgui --tool pin-cells merged.json cell=bel ...
#include <exception>
#include <string>
#include "../common/pycompat.hpp"
#include "../common/toolio.hpp"

namespace pin_cells_tool {

using std::string;
using pycompat::V;

int tool_main(int argc, char** argv) {
    if (argc < 2) {
        toolio::err("usage: pin-cells merged.json cell=bel ...\n");
        return 2;
    }
    try {
        const string path = argv[1];
        V j = pycompat::load(path);
        V* m = nullptr;
        size_t most = 0;
        for (auto& kv : j.at("modules").o().items()) {
            size_t n = kv.second.at("cells").o().size();
            if (!m || n > most) { m = &kv.second; most = n; }
        }
        if (!m) throw std::runtime_error("max() of no modules");
        for (int i = 2; i < argc; i++) {
            const string arg = argv[i];
            size_t eq = arg.find('=');
            if (eq == string::npos) throw std::runtime_error("not cell=bel: " + arg);
            const string cell = arg.substr(0, eq), bel = arg.substr(eq + 1);
            m->at("cells").at(cell).at("attributes").o().set("BEL", bel);
            toolio::out("%s pinned to %s\n", cell.c_str(), bel.c_str());
        }
        pycompat::dump_file(j, path, 1);
        return 0;
    } catch (std::exception& e) {
        toolio::err("pin_cells: %s\n", e.what());
        return 1;
    }
}

}  // namespace pin_cells_tool

int pin_cells_main(int argc, char** argv) {
    try {
        return pin_cells_tool::tool_main(argc, argv);
    } catch (toolio::Exit& e) {
        return e.code;
    }
}
