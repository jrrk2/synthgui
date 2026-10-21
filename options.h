// options.h - the tool options the Synthesis and Place & route panels set.
//
// Each option knows its command-line form; a project file keeps the ones that
// are turned on ("options": {"pnr.router": "router2", ...}) and the panels
// build {synth_options} and {nextpnr_flags} from them.  Options marked qor
// change what the tools produce (area, Fmax, routability); the rest change
// only what is written or kept.
#pragma once

#include <QMap>
#include <QRegularExpression>
#include <QString>
#include <QStringList>
#include <vector>

struct OptionSpec {
    enum Kind { Bool, Int, Real, Choice, Text };
    const char* key;     // "<stage>.<name>", as kept in the project file
    const char* label;
    Kind kind;
    const char* def;     // the value offered when the option is turned on
    const char* flag;    // command-line form; {} is the value
    bool qor;
    const char* tip;
    const char* choices = "";  // Choice: "value|label\nvalue|label" (an ABC script has ';' in it)
    double lo = 0, hi = 1e9;   // Int/Real range

    QString stage() const { return QString(key).section('.', 0, 0); }
    QList<QPair<QString, QString>> choiceList() const {
        QList<QPair<QString, QString>> l;
        for (const QString& c : QString(choices).split('\n', Qt::SkipEmptyParts))
            l << qMakePair(c.section('|', 0, 0), c.section('|', 1));
        return l;
    }
};

inline const std::vector<OptionSpec>& optionSpecs() {
    static const std::vector<OptionSpec> specs = {
        // ---- synthesis: Verilator's --map-only-output (libabc for the LUTs)
        {"synth.abc_script", "LUT mapping script", OptionSpec::Choice, "strash; dc2; if -K 6",
         "--map-only-abc-script {}", true,
         "The ABC commands between reading the AIG and writing the LUT netlist; the last must map to 6-LUTs. "
         "Area trades depth for fewer LUTs, delay uses structural choices for shallower logic.",
         "strash; dc2; if -K 6|Balanced (the default)\n"
         "strash; dc2; if -K 6 -a|Area: fewest LUTs\n"
         "strash; dch -f; if -K 6|Delay: structural choices\n"
         "strash; resyn2; if -K 6|resyn2, then map\n"
         "strash; dch -f; if -K 6; mfs2|Delay, then don't-care resynthesis"},
        {"synth.bram_cascade", "Cascade deep block RAMs", OptionSpec::Bool, "1", "--map-only-bram-cascade", true,
         "Memories deeper than 32K words are built from 32K x1 RAMB36s; this pairs them over the column's "
         "cascade wires into 64K x1 memories (LOWER/UPPER, as Vivado does), halving the LUT multiplexer "
         "behind every data bit.  An odd number of blocks is padded with one.  Needs a nextpnr that places "
         "cascaded pairs (openXC7 main since #67)."},
        {"synth.wide_packed_mem", "Wide vectors as memories", OptionSpec::Bool, "1",
         "--struct-only-wide-packed-mem", true,
         "Treat packed vectors wider than 512 bits as flattened memories, so they can become block RAM."},
        {"synth.edif_flat", "Flat EDIF", OptionSpec::Bool, "1", "--map-only-edif-flat", false,
         "Write the EDIF as one flat cell rather than with the design's hierarchy."},
        {"synth.keep_temps", "Keep ABC's files", OptionSpec::Bool, "1", "--map-only-keep-temps", false,
         "Keep the AIGER and BLIF files handed to and from ABC beside the netlist."},

        // ---- place and route: nextpnr-himbaechel (xilinx)
        {"pnr.placer", "Placer", OptionSpec::Choice, "heap", "--placer {}", true,
         "Analytic (HeAP) or simulated annealing.", "heap|HeAP (analytic)\nsa|Simulated annealing"},
        {"pnr.no_tmdriv", "No timing-driven placement", OptionSpec::Bool, "1", "--no-tmdriv", true,
         "Place for wirelength only."},
        {"pnr.timingweight", "Placer timing weight", OptionSpec::Int, "100", "--placer-heap-timingweight {}", true,
         "How hard HeAP pulls critical connections together (nextpnr's default is 10). "
         "The 1 GB LiteX SoC needs 100 with the measured delay matrix to reach 100 MHz.", "", 0, 1000},
        {"pnr.cong_spread", "Congestion spreading", OptionSpec::Bool, "1", "--placer-heap-congestion-spread", true,
         "Push cells out of regions whose routing is congested."},
        {"pnr.cong_weight", "Congestion weight", OptionSpec::Real, "1.0", "--placer-heap-congestion-weight {}", true,
         "How hard congested tiles are penalised under congestion spreading.", "", 0, 100},
        {"pnr.delay_matrix", "Delay model", OptionSpec::Text, "build", "-o delay-matrix={}", true,
         "Interconnect delay estimates for placement: build (measure them), off (the tuned formula), "
         "or a file that caches the measured table."},
        {"pnr.timing_opt", "Timing optimisation (radius,rounds)", OptionSpec::Text, "2,30", "-o timing-opt={}", true,
         "After placing, move cells on critical paths within this radius for this many rounds. "
         "Needs a nextpnr with --timing-opt (xc7-bitstream-tools' timing-opt-radius-iterations)."},
        {"pnr.router", "Router", OptionSpec::Choice, "router2", "--router {}", true,
         "router2 is the faster, congestion-negotiating router.", "router2|router2\nrouter1|router1"},
        {"pnr.tmg_ripup", "Timing-driven rip-up", OptionSpec::Bool, "1", "--tmg-ripup", true,
         "Let the router rip up and reroute nets to improve timing."},
        {"pnr.alt_weights", "router2 alternate weights", OptionSpec::Bool, "1", "--router2-alt-weights", true,
         "router2's alternate cost weights."},
        {"pnr.hold_fix", "Hold fixing (passes)", OptionSpec::Int, "8", "-o hold-fix={}", true,
         "After routing, fix hold violations by detours or feedthrough LUTs.", "", 1, 100},
        {"pnr.seed", "Seed", OptionSpec::Int, "1", "--seed {}", true,
         "Seed for the placer's random choices.", "", 0, 1e9},
        {"pnr.freq", "Target frequency (MHz)", OptionSpec::Real, "100", "--freq {}", true,
         "The clock target where the constraints give none.", "", 1, 2000},
        {"pnr.allow_fail", "Allow timing failure", OptionSpec::Bool, "1", "--timing-allow-fail", false,
         "Write the result even when a clock misses its target."},
    };
    return specs;
}

// A word as bash reads it: quoted unless it is plainly safe
inline QString shellWord(const QString& w) {
    static const QRegularExpression plain("^[A-Za-z0-9_./+=:,@%-]+$");
    if (plain.match(w).hasMatch()) return w;
    QString e = w;
    return "'" + e.replace("'", "'\\''") + "'";
}

// The command-line arguments for one stage: every option that is on, then the
// stage's additional flags (kept as typed)
inline QString optionArgs(const QString& stage, const QMap<QString, QString>& on) {
    QStringList out;
    for (const OptionSpec& s : optionSpecs()) {
        if (s.stage() != stage || !on.contains(s.key)) continue;
        QStringList words = QString(s.flag).split(' ');
        for (QString& w : words) {
            if (!w.contains("{}")) continue;
            w = shellWord(QString(w).replace("{}", on.value(s.key)));
        }
        out << words.join(' ');
    }
    const QString extra = on.value(stage + ".extra").trimmed();
    if (!extra.isEmpty()) out << extra;
    return out.join(' ');
}

// Read a flag string (a project's old nextpnr_flags) back into options: the
// words an option knows become that option, the rest the stage's extra flags
inline void parseOptionArgs(const QString& stage, const QString& flags, QMap<QString, QString>& on) {
    const QStringList w = flags.split(QRegularExpression("\\s+"), Qt::SkipEmptyParts);
    QStringList extra;
    for (int i = 0; i < w.size();) {
        bool matched = false;
        for (const OptionSpec& s : optionSpecs()) {
            if (s.stage() != stage) continue;
            const QStringList t = QString(s.flag).split(' ');
            if (i + t.size() > w.size()) continue;
            QString value = s.kind == OptionSpec::Bool ? "1" : QString();
            bool ok = true;
            for (int k = 0; k < t.size() && ok; ++k) {
                const int at = t[k].indexOf("{}");
                if (at < 0) { ok = w[i + k] == t[k]; continue; }
                const QString pre = t[k].left(at);
                if (w[i + k].startsWith(pre) && w[i + k].size() > pre.size()) value = w[i + k].mid(pre.size());
                else if (pre.endsWith('=') && w[i + k] == pre.chopped(1)) value = s.def;  // -o hold-fix: the default
                else ok = false;
            }
            if (!ok) continue;
            on[s.key] = value;
            i += t.size();
            matched = true;
            break;
        }
        if (!matched) extra << w[i++];
    }
    if (!extra.isEmpty()) on[stage + ".extra"] = extra.join(' ');
}
