// synthgui: a proof-of-concept front end for the open FPGA flow
//
//   edit SystemVerilog and XDC  ->  verilator --map-only-output (libabc in process)
//   -> nextpnr-himbaechel -> fasm2netlist LVS -> prjxray bitstream -> openFPGALoader
//
// Stage one of the plan: every tool is a separate process, driven through a
// command template in the project file, so a step can change without
// rebuilding this program.  The results views (area, timing, chip plot,
// problems) parse what the tools write.  Later stages replace processes with
// in-process libraries sharing one netlist and one chip database.
//
//   synthgui --project p.json                         interactive
//   synthgui --project p.json --screenshot out.png [--view chip|area|timing|log|edit]
//                                                     render one view from existing results and exit

#include <QApplication>
#include <QSettings>
#include <QMenu>
#include <QMenuBar>
#include <QAction>
#include <QIcon>
#include <QCheckBox>
#include <QDoubleSpinBox>
#include <QGroupBox>
#include <QSaveFile>
#include <QScrollArea>
#include <QSpinBox>
#include <QCloseEvent>
#include <functional>
#include <QCommandLineParser>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QGraphicsEllipseItem>
#include <QGraphicsRectItem>
#include <QGraphicsScene>
#include <QGraphicsSimpleTextItem>
#include <QGraphicsView>
#include <QHeaderView>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLabel>
#include <QListWidget>
#include <QComboBox>
#include <QDialog>
#include <QDialogButtonBox>
#include <QFileDialog>
#include <QFormLayout>
#include <QHBoxLayout>
#include <QLineEdit>
#include <QPushButton>
#include <QStandardPaths>
#include <QMainWindow>
#include <QMap>
#include <QMessageBox>
#include <QPlainTextEdit>
#include <cstring>
#include <QProcess>
#include <QMetaObject>
#include <QThread>
#include <QProcessEnvironment>
#include <QRegularExpression>
#include <QSet>
#include <QShortcut>
#include <QSplitter>
#include <QStackedWidget>
#include <QStatusBar>
#include <QSyntaxHighlighter>
#include <QTabWidget>
#include <QTableWidget>
#include <QTextBlock>
#include <QTimer>
#include <QToolBar>
#include <QTreeWidget>
#include <QVBoxLayout>
#include <QWheelEvent>

#include "options.h"
#include "tools/common/toolio.hpp"

// tools/: the converters the pipeline steps run as `synthgui --tool NAME`
int fasm2frames_main(int argc, char** argv);
int bit2uf2_main(int argc, char** argv);
int sta_prep_main(int argc, char** argv);
int bram_fom_main(int argc, char** argv);

// ---------------------------------------------------------------- project

// A project file: what to build and how.  Command templates use {name}
// placeholders for any of the string fields and for derived paths
// ({work}, {json}, {edif}, {fasm}, {placement}, {bit}, {sources}, {incdirs},
// {defines}, {blackboxes}).
struct Step {
    QString id, label, command;
    // writes the board's non-volatile memory (a UF2 copied to its USB drive): Run all leaves it out unless Settings says
    // otherwise. A project step says so with "nonvolatile": true; program_uf2 is one without having to.
    bool nonvolatile = false;
    bool operator==(const Step& o) const { return id == o.id; }
};
struct Project {
    QString path, dir, name, top, work, device, part, xdc;
    QStringList sources, incdirs, defines, blackboxes;
    QMap<QString, QString> vars;  // every string field, for templates
    QList<Step> steps;
    QMap<QString, int> capacity;  // device resources for utilisation
    QMap<QString, QString> options;  // the tool options that are on (options.h), and each stage's extra flags

    QString abs(const QString& p) const { return QDir::isAbsolutePath(p) ? p : QDir(dir).filePath(p); }
    // {root} is the checkout, {deps} the submodules, {prefix} where scripts/build-deps.sh installs; both sit
    // next to build/ like sta/ and projects/
    // --work DIR: the work directory of whichever project is loaded, in place of its own (used by scripts/ci-flow.sh)
    static inline QString workOverride;
    // Inside synthgui.app (Contents/MacOS/synthgui) the same tree lives in Contents/Resources.
    static QString repoRoot() {
        const QString app = QCoreApplication::applicationDirPath();
        if (app.endsWith("/Contents/MacOS")) return QDir(app + "/../Resources").absolutePath();
        QDir d(app);
#ifdef Q_OS_WIN
        // multi-config generators (Visual Studio) put the exe in build/Release
        static const QStringList configs{"Release", "Debug", "RelWithDebInfo", "MinSizeRel"};
        if (configs.contains(d.dirName(), Qt::CaseInsensitive)) d.cdUp();
#endif
        return QDir(d.absolutePath() + "/..").absolutePath();
    }
    // Inside synthgui.app the tools sit in Contents/Resources/build-deps (scripts/bundle-tools.py): steps run with
    // them first on PATH.
    static bool bundled() { return QCoreApplication::applicationDirPath().endsWith("/Contents/MacOS"); }
    static QProcessEnvironment bundledEnvironment() {
        QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
        const QString b = repoRoot() + "/build-deps";
        env.insert("PATH", b + "/prefix/bin:" + env.value("PATH", "/usr/bin:/bin:/usr/sbin:/sbin"));
        env.insert("TCL_LIBRARY", b + "/prefix/lib/tcl8.6");
        return env;
    }
    static QString expandHome(QString s) {
        if (s.startsWith("~/")) s = QDir::homePath() + s.mid(1);
        s.replace("{root}", repoRoot());
        s.replace("{deps}", repoRoot() + "/deps");
        s.replace("{prefix}", repoRoot() + "/build-deps/prefix");
        s.replace("{builds}", repoRoot() + "/build-deps");
        return s;
    }
    bool load(const QString& file, QString& err) {
        QFile f(file);
        if (!f.open(QIODevice::ReadOnly)) { err = "cannot open " + file; return false; }
        QJsonParseError pe;
        const QJsonDocument doc = QJsonDocument::fromJson(f.readAll(), &pe);
        if (doc.isNull()) { err = pe.errorString(); return false; }
        const QJsonObject o = doc.object();
        path = QFileInfo(file).absoluteFilePath();
        dir = QFileInfo(file).absolutePath();
        for (auto it = o.begin(); it != o.end(); ++it)
            if (it.value().isString()) vars[it.key()] = expandHome(it.value().toString());
        if (!workOverride.isEmpty()) vars["work"] = workOverride;
        name = vars.value("name", QFileInfo(file).baseName());
        top = vars.value("top");
        work = abs(vars.value("work", "build"));
        device = vars.value("device");
        part = vars.value("part");
        xdc = vars.contains("xdc") ? abs(vars.value("xdc")) : QString();
        auto list = [&](const char* k) {
            QStringList l;
            for (const auto& v : o.value(k).toArray()) l << expandHome(v.toString());
            return l;
        };
        for (const QString& s : list("sources")) sources << abs(s);
        for (const QString& s : list("incdirs")) incdirs << abs(s);
        defines = list("defines");
        blackboxes = list("blackboxes");
        for (const auto& v : o.value("steps").toArray()) {
            const QJsonObject s = v.toObject();
            Step st{s.value("id").toString(), s.value("label").toString(), s.value("command").toString()};
            st.nonvolatile = s.value("nonvolatile").toBool(st.id == "program_uf2");
            // the Synthesis panel's options go at the end of the synthesis command
            if (st.id == "synth" && !st.command.contains("{synth_options}")) st.command += " {synth_options}";
            steps << st;
        }
        // Options: the panels' own record, or (a project from before them) the
        // nextpnr flags read back into options, what is not one kept as typed
        const QJsonObject oo = o.value("options").toObject();
        for (auto it = oo.begin(); it != oo.end(); ++it) options[it.key()] = it.value().toString();
        bool anyPnr = false;
        for (auto it = options.begin(); it != options.end(); ++it) anyPnr |= it.key().startsWith("pnr.");
        if (!anyPnr) parseOptionArgs("pnr", o.value("nextpnr_flags").toString(), options);
        applyOptions();
        const QJsonObject cap = o.value("capacity").toObject();
        for (auto it = cap.begin(); it != cap.end(); ++it) capacity[it.key()] = it.value().toInt();
        vars["root"] = repoRoot();
        vars["deps"] = repoRoot() + "/deps";
        vars["prefix"] = repoRoot() + "/build-deps/prefix";
        vars["builds"] = repoRoot() + "/build-deps";
        vars["work"] = work;
        vars["json"] = work + "/" + top + ".json";
        vars["edif"] = work + "/" + top + ".edf";
        vars["fasm"] = work + "/" + top + ".fasm";
        vars["placement"] = work + "/" + top + "_placement.json";
        vars["bit"] = work + "/" + top + ".bit";
        vars["routed"] = work + "/" + top + "_routed.json";
        vars["sdf"] = work + "/" + top + ".sdf";
        vars["xdc"] = xdc;
        // the tools built into this program (tools/) are run in-process: a step's command names one as @name
        for (const char* tool : {"fasm2frames", "bit2uf2", "sta_prep", "bram_fom"})
            if (!vars.contains(tool)) vars[tool] = QString("@") + tool;
        if (!vars.contains("frames2bit")) vars["frames2bit"] = repoRoot() + "/build-deps/prjxray/tools/xc7frames2bit";
        // commands run through bash: quote anything the shell would read (32'h... in a define)
        auto q = [](const QString& w) {
            static const QRegularExpression plain("^[A-Za-z0-9_./+=:,@%-]+$");
            if (plain.match(w).hasMatch()) return w;
            QString e = w;
            return "'" + e.replace("'", "'\\''") + "'";
        };
        QStringList src, inc, def, bb;
        for (const QString& f : sources) src << q(f);
        vars["sources"] = src.join(' ');
        for (const QString& i : incdirs) inc << q("-I" + i);
        for (const QString& d : defines) def << q("+define+" + d);
        for (const QString& b : blackboxes) bb << "--struct-only-blackbox " + b;
        vars["incdirs"] = inc.join(' ');
        vars["defines"] = def.join(' ');
        vars["blackboxes"] = bb.join(' ');
        return true;
    }
    void applyOptions() {
        vars["synth_options"] = expandHome(optionArgs("synth", options));
        vars["nextpnr_flags"] = expandHome(optionArgs("pnr", options));
        // the figure of merit prices routes with the placer's delay matrix: the
        // file when the Delay model names one, else nextpnr's fallback formula
        const QString dm = options.value("pnr.delay_matrix");
        const bool dm_is_a_file = !dm.isEmpty() && dm != "build" && dm != "off";
        vars["delay_matrix_file"] = dm_is_a_file ? expandHome(dm) : "formula";
    }
    // Write the options back into the project file, leaving the rest of it as it is
    bool saveOptions(QString& err) const {
        QFile in(path);
        if (!in.open(QIODevice::ReadOnly)) { err = "cannot read " + path; return false; }
        QJsonObject o = QJsonDocument::fromJson(in.readAll()).object();
        in.close();
        QJsonObject oo;
        for (auto it = options.begin(); it != options.end(); ++it) oo[it.key()] = it.value();
        o["options"] = oo;
        o["nextpnr_flags"] = optionArgs("pnr", options);  // for anything that reads the flags directly
        QSaveFile out(path);
        if (!out.open(QIODevice::WriteOnly)) { err = "cannot write " + path; return false; }
        out.write(QJsonDocument(o).toJson(QJsonDocument::Indented));
        if (!out.commit()) { err = "cannot write " + path; return false; }
        return true;
    }
    QString expand(QString t) const {
        for (int pass = 0; pass < 3; ++pass)  // templates may refer to each other
            for (auto it = vars.begin(); it != vars.end(); ++it) t.replace("{" + it.key() + "}", it.value());
        return t;
    }
    QString logPath(const QString& stepId) const { return work + "/" + stepId + ".log"; }
};

// ---------------------------------------------------------------- editor

class HdlHighlighter final : public QSyntaxHighlighter {
public:
    HdlHighlighter(QTextDocument* doc, bool xdc) : QSyntaxHighlighter(doc) {
        QTextCharFormat kw, num, com, str;
        kw.setForeground(QColor(0x1f, 0x5f, 0xbf));
        kw.setFontWeight(QFont::Bold);
        num.setForeground(QColor(0x9a, 0x50, 0x00));
        com.setForeground(QColor(0x50, 0x80, 0x50));
        com.setFontItalic(true);
        str.setForeground(QColor(0xa0, 0x20, 0x40));
        const char* words = xdc
            ? "set_property|create_clock|create_generated_clock|set_clock_groups|set_false_path|get_ports|get_pins|get_clocks|get_cells|PACKAGE_PIN|IOSTANDARD"
            : "module|endmodule|input|output|inout|wire|reg|logic|always|always_ff|always_comb|assign|begin|end|if|else|case|endcase|for|generate|endgenerate|parameter|localparam|posedge|negedge|function|endfunction|task|endtask|initial|integer|genvar|default|typedef|enum|struct|packed";
        rules << Rule{QRegularExpression(QString("\\b(%1)\\b").arg(words)), kw};
        rules << Rule{QRegularExpression("\\b\\d+'[sS]?[bBoOdDhH][0-9a-fA-FxXzZ_]+\\b|\\b\\d+\\b"), num};
        rules << Rule{QRegularExpression("\"[^\"]*\""), str};
        rules << Rule{QRegularExpression(xdc ? "#.*$" : "//.*$"), com};
    }

protected:
    void highlightBlock(const QString& text) override {
        for (const Rule& r : rules) {
            auto it = r.re.globalMatch(text);
            while (it.hasNext()) {
                const auto m = it.next();
                setFormat(m.capturedStart(), m.capturedLength(), r.fmt);
            }
        }
    }

private:
    struct Rule {
        QRegularExpression re;
        QTextCharFormat fmt;
    };
    QList<Rule> rules;
};

// ---------------------------------------------------------------- chip plot

class ChipView final : public QGraphicsView {
public:
    explicit ChipView(QWidget* parent = nullptr) : QGraphicsView(parent) {
        setScene(&m_scene);
        setRenderHint(QPainter::Antialiasing, false);
        setDragMode(QGraphicsView::ScrollHandDrag);
        setBackgroundBrush(QColor(0x1b, 0x1d, 0x22));
    }
    // placement: cell -> {nextpnr_bel "X..Y../...", type}; hot: cells on failing paths
    int load(const QString& placementFile, const QSet<QString>& hot, QString& summary) {
        m_scene.clear();
        m_pathItems.clear();
        m_mark = nullptr;
        m_pos.clear();
        QFile f(placementFile);
        if (!f.open(QIODevice::ReadOnly)) { summary = "no placement yet (" + placementFile + ")"; return 0; }
        const QJsonObject cells = QJsonDocument::fromJson(f.readAll()).object();
        static const QRegularExpression xy("^X(\\d+)Y(\\d+)/");
        QMap<QString, int> counts;
        int maxX = 0, maxY = 0, n = 0;
        struct P { int x, y; QString kind; bool hot; QString tip; };
        QList<P> pts;
        for (auto it = cells.begin(); it != cells.end(); ++it) {
            const QJsonObject c = it.value().toObject();
            const auto m = xy.match(c.value("nextpnr_bel").toString());
            if (!m.hasMatch()) continue;
            const QString bel = c.value("bel").toString();
            const QString kind = classify(c.value("type").toString(), bel);
            const int x = m.captured(1).toInt(), y = m.captured(2).toInt();
            maxX = std::max(maxX, x);
            maxY = std::max(maxY, y);
            pts << P{x, y, kind, hot.contains(it.key()),
                     QString("%1\n%2  %3\n%4").arg(it.key(), c.value("type").toString(), c.value("site").toString(), c.value("tile").toString())};
            m_pos[it.key()] = QPointF(x * 3.0, y * 3.0);
            counts[kind]++;
            ++n;
        }
        const qreal s = 3.0;
        m_scene.addRect(-2, -2, (maxX + 2) * s, (maxY + 2) * s, QPen(QColor(0x50, 0x55, 0x60)), Qt::NoBrush);
        for (const P& p : pts) {
            if (p.hot) continue;
            const QColor col = colour(p.kind);
            QGraphicsRectItem* r;
            if (p.kind == "BRAM" || p.kind == "DSP")  // a RAMB36 / DSP48 pair spans five tile rows
                r = m_scene.addRect(p.x * s - s, p.y * s, s * 2.6, s * 4.6, QPen(col.darker(140)), col);
            else
                r = m_scene.addRect(p.x * s, p.y * s, s * 0.9, s * 0.9, Qt::NoPen, col);
            r->setToolTip(p.tip);
        }
        int nhot = 0;
        for (const P& p : pts) {  // failing-path cells on top, large
            if (!p.hot) continue;
            auto* e = m_scene.addEllipse(p.x * s - 3, p.y * s - 3, 9, 9, QPen(QColor(255, 255, 255), 1), QColor(0xff, 0x30, 0x30));
            e->setToolTip(p.tip);
            e->setZValue(2);
            ++nhot;
        }
        // legend (a label beside the view, so it keeps its size when zoomed)
        QString html = "<table cellspacing=4>";
        for (const QString& k : {QString("LUT"), QString("FF"), QString("BRAM"), QString("LUTRAM"), QString("DSP"), QString("IO"), QString("CLOCK"), QString("GT"), QString("other")}) {
            if (!counts.contains(k)) continue;
            html += QString("<tr><td style='background:%1'>&nbsp;&nbsp;&nbsp;</td><td>%2</td><td align=right>%3</td></tr>").arg(colour(k).name(), k).arg(counts[k]);
        }
        if (nhot) html += QString("<tr><td style='background:#ff3030'>&nbsp;&nbsp;&nbsp;</td><td>critical path</td><td align=right>%1</td></tr>").arg(nhot);
        html += "</table>";
        m_legendHtml = html;
        setSceneRect(m_scene.itemsBoundingRect().adjusted(-10, -10, 10, 10));
        summary = QString("%1 placed cells, %2 on failing paths").arg(n).arg(nhot);
        return n;
    }
    void fit() { fitInView(sceneRect(), Qt::KeepAspectRatio); }
    // the critical path as a polyline through its nets' (x,y) -> (x,y) hops
    void drawPath(const QList<QPair<QPointF, QPointF>>& hops) {
        for (auto* it : m_pathItems) { m_scene.removeItem(it); delete it; }
        m_pathItems.clear();
        QPen pen(QColor(0xff, 0xe0, 0x40), 1.6);
        pen.setCosmetic(true);
        for (const auto& h : hops) {
            auto* l = m_scene.addLine(QLineF(h.first * 3.0, h.second * 3.0), pen);
            l->setZValue(3);
            m_pathItems << l;
        }
    }
    bool gridPos(const QString& cell, QPointF& g) const {
        if (!m_pos.contains(cell)) return false;
        g = m_pos[cell] / 3.0;
        return true;
    }
    void focus(const QString& cell, const QPointF& fallback) {
        if (m_mark) { m_scene.removeItem(m_mark); delete m_mark; m_mark = nullptr; }
        const QPointF c = m_pos.contains(cell) ? m_pos[cell] : fallback * 3.0;
        QPen pen(QColor(0x40, 0xff, 0xff), 2);
        pen.setCosmetic(true);
        m_mark = m_scene.addEllipse(c.x() - 8, c.y() - 8, 18, 18, pen, Qt::NoBrush);
        m_mark->setZValue(4);
        if (transform().m11() < 2.0) { resetTransform(); scale(4, 4); }
        centerOn(c);
    }
    QString legendHtml() const { return m_legendHtml; }

protected:
    void wheelEvent(QWheelEvent* e) override {
        const qreal f = e->angleDelta().y() > 0 ? 1.25 : 0.8;
        scale(f, f);
    }

private:
    static QString classify(const QString& type, const QString& bel) {
        if (type.startsWith("LUT") || bel.contains("LUT")) return "LUT";
        if (type.startsWith("FD") || bel.contains("FF")) return "FF";
        if (type.startsWith("RAMB") || bel.startsWith("RAMB")) return "BRAM";
        if (type.startsWith("RAM") || bel.contains("RAM")) return "LUTRAM";
        if (type.startsWith("DSP")) return "DSP";
        if (type == "PAD" || type.contains("BUF") || bel.startsWith("IOB")) return type.startsWith("BUFG") ? "CLOCK" : "IO";
        if (type.startsWith("MMCM") || type.startsWith("PLL") || type.startsWith("BUFG")) return "CLOCK";
        if (type.startsWith("GT") || type.startsWith("IBUFDS_GTE")) return "GT";
        return "other";
    }
    static QColor colour(const QString& k) {
        if (k == "LUT") return QColor(0x3f, 0xb9, 0x50);
        if (k == "FF") return QColor(0x3d, 0x8b, 0xff);
        if (k == "BRAM") return QColor(0xff, 0xa2, 0x2e);
        if (k == "LUTRAM") return QColor(0xd2, 0x6e, 0xff);
        if (k == "DSP") return QColor(0xff, 0x6e, 0xc7);
        if (k == "IO") return QColor(0xb0, 0xb0, 0xb0);
        if (k == "CLOCK") return QColor(0xff, 0xff, 0x60);
        if (k == "GT") return QColor(0x40, 0xe0, 0xe0);
        return QColor(0x80, 0x80, 0x80);
    }
    QGraphicsScene m_scene;
    QString m_legendHtml;
    QMap<QString, QPointF> m_pos;  // cell -> scene position
    QList<QGraphicsItem*> m_pathItems;
    QGraphicsEllipseItem* m_mark = nullptr;
};

// ---------------------------------------------------------------- main window


// ---------------------------------------------------------------- new project
// Everything a project needs that is not toolchain plumbing.  The toolchain paths,
// steps and device capacity come from a template project (projects/*.json next to
// the binary), so a new project starts from a flow that is known to work.
class NewProjectDialog final : public QDialog {
public:
    QString created;  // path of the written project file
    ~NewProjectDialog() override { qDeleteAll(m_rows); }
    explicit NewProjectDialog(QWidget* parent = nullptr) : QDialog(parent) {
        setWindowTitle("synthgui - new project");
        resize(820, 640);
        auto* form = new QFormLayout;

        m_template = new QComboBox;
        const QDir pd(projectsDir());
        for (const QString& f : pd.entryList({"*.json"}, QDir::Files, QDir::Name)) m_template->addItem(f, pd.filePath(f));
        form->addRow("Flow template", m_template);
        connect(m_template, &QComboBox::currentIndexChanged, this, [this] { loadTemplate(); });

        m_name = new QLineEdit;
        m_name->setPlaceholderText("e.g. vc707_myboard");
        form->addRow("Project name", m_name);
        connect(m_name, &QLineEdit::textEdited, this, [this] { followName(); });

        m_sources = new QListWidget;
        m_sources->setSelectionMode(QAbstractItemView::ExtendedSelection);
        form->addRow("Sources\n(compile order)", listWithButtons(m_sources, {
            {"Add files...", [this] { addSources(QFileDialog::getOpenFileNames(this, "HDL sources", lastDir(), "HDL (*.sv *.v *.svh *.vh);;All files (*)")); }},
            {"Add folder...", [this] { addFolder(); }},
            {"Up", [this] { move(m_sources, -1); }},
            {"Down", [this] { move(m_sources, +1); }},
            {"Remove", [this] { qDeleteAll(m_sources->selectedItems()); guessTop(); }}}));

        m_top = new QComboBox;
        m_top->setEditable(true);
        form->addRow("Top module", m_top);
        connect(m_top, &QComboBox::currentTextChanged, this, [this] { guessXdc(); });

        m_incdirs = new QListWidget;
        m_incdirs->setMaximumHeight(80);
        form->addRow("Include dirs", listWithButtons(m_incdirs, {
            {"Add...", [this] { const QString d = QFileDialog::getExistingDirectory(this, "Include directory", lastDir()); if (!d.isEmpty()) addUnique(m_incdirs, d); }},
            {"Remove", [this] { qDeleteAll(m_incdirs->selectedItems()); }}}));

        m_defines = new QLineEdit;
        m_defines->setToolTip("space separated; NAME or NAME=VALUE");
        form->addRow("Defines", m_defines);

        m_xdc = pathRow(form, "Constraints (XDC)", false, "Xilinx constraints (*.xdc);;All files (*)");
        m_srcdir = pathRow(form, "Memory init dir", true, QString());
        m_srcdir->first->setToolTip("where $readmemh/$readmemb and INIT_FILE files are found");

        m_blackboxes = new QLineEdit;
        m_blackboxes->setToolTip("primitives kept as cells instead of being synthesised (space separated)");
        form->addRow("Black boxes", m_blackboxes);
        m_part = new QLineEdit;
        form->addRow("Part", m_part);

        m_work = pathRow(form, "Work directory", true, QString());
        m_file = new QLineEdit;
        auto* fb = new QPushButton("Browse...");
        connect(fb, &QPushButton::clicked, this, [this] {
            const QString f = QFileDialog::getSaveFileName(this, "Project file", m_file->text(), "synthgui project (*.json)");
            if (!f.isEmpty()) { m_file->setText(f.endsWith(".json") ? f : f + ".json"); m_fileTouched = true; }
        });
        auto* fr = new QHBoxLayout;
        fr->addWidget(m_file);
        fr->addWidget(fb);
        form->addRow("Project file", fr);
        connect(m_file, &QLineEdit::textEdited, this, [this] { m_fileTouched = true; });
        connect(m_work->first, &QLineEdit::textEdited, this, [this] { m_workTouched = true; });
        connect(m_xdc->first, &QLineEdit::textEdited, this, [this] { m_xdcAuto = false; });

        auto* buttons = new QDialogButtonBox;
        auto* openBtn = buttons->addButton("Open existing...", QDialogButtonBox::ActionRole);
        buttons->addButton("Create", QDialogButtonBox::AcceptRole);
        buttons->addButton(QDialogButtonBox::Cancel);
        connect(openBtn, &QPushButton::clicked, this, [this] {
            const QString f = QFileDialog::getOpenFileName(this, "Open project", projectsDir(), "synthgui project (*.json)");
            if (!f.isEmpty()) { created = f; QDialog::accept(); }
        });
        connect(buttons, &QDialogButtonBox::accepted, this, [this] { create(); });
        connect(buttons, &QDialogButtonBox::rejected, this, &QDialog::reject);

        auto* v = new QVBoxLayout(this);
        v->addLayout(form);
        v->addWidget(buttons);
        loadTemplate();
    }
    static QString projectsDir() { return QDir(Project::repoRoot() + "/projects").absolutePath(); }

    // for --selftest-new: fill the form as a user would, then press Create
    void fill(const QString& name, const QStringList& sources, const QString& xdc, const QString& work, const QString& file) {
        m_name->setText(name);
        followName();
        addSources(sources);
        if (!xdc.isEmpty()) { m_xdc->first->setText(xdc); m_xdcAuto = false; }  // otherwise keep what was found beside the sources
        if (!work.isEmpty()) { m_work->first->setText(work); m_workTouched = true; }
        if (!file.isEmpty()) { m_file->setText(file); m_fileTouched = true; }
        m_batch = true;  // no one to answer questions: take the default yes
    }
    void create() {
        auto fail = [this](const QString& m) {
            if (m_batch) qWarning("new project: %s", qPrintable(m));
            else QMessageBox::warning(this, "new project", m);
        };
        const QString name = m_name->text().trimmed(), top = m_top->currentText().trimmed(), file = m_file->text().trimmed();
        if (name.isEmpty()) return fail("Give the project a name.");
        if (m_sources->count() == 0) return fail("Add at least one source file.");
        if (top.isEmpty()) return fail("Choose the top module.");
        if (file.isEmpty()) return fail("Choose where to save the project file.");
        if (m_xdc->first->text().trimmed().isEmpty() && !ask("No constraints file: place and route will have no pins or clocks. Continue?"))
            return;
        if (QFileInfo::exists(file) && !ask(file + " exists. Replace it?"))
            return;
        QJsonObject o = m_tmpl;
        o["name"] = name;
        o["top"] = top;
        o["work"] = home(m_work->first->text().trimmed());
        o["xdc"] = home(m_xdc->first->text().trimmed());
        o["srcdir"] = home(m_srcdir->first->text().trimmed());
        o["part"] = m_part->text().trimmed();
        o["device"] = m_part->text().trimmed().section(QRegularExpression("(ff|fb|sb|cs|cl|rb|rs)g?\\d"), 0, 0);
        auto arr = [](const QStringList& l) { QJsonArray a; for (const QString& x : l) a.append(x); return a; };
        QStringList src, inc;
        for (int i = 0; i < m_sources->count(); ++i) src << home(m_sources->item(i)->text());
        for (int i = 0; i < m_incdirs->count(); ++i) inc << home(m_incdirs->item(i)->text());
        o["sources"] = arr(src);
        o["incdirs"] = arr(inc);
        o["defines"] = arr(m_defines->text().split(' ', Qt::SkipEmptyParts));
        o["blackboxes"] = arr(m_blackboxes->text().split(' ', Qt::SkipEmptyParts));
        QDir().mkpath(QFileInfo(file).absolutePath());
        QFile f(file);
        if (!f.open(QIODevice::WriteOnly)) return fail("Cannot write " + file);
        f.write(QJsonDocument(o).toJson(QJsonDocument::Indented));
        created = QFileInfo(file).absoluteFilePath();
        QDialog::accept();
    }

private:
    QComboBox* m_template;
    QLineEdit *m_name, *m_defines, *m_blackboxes, *m_part, *m_file;
    QListWidget *m_sources, *m_incdirs;
    QComboBox* m_top;
    QPair<QLineEdit*, bool>* m_xdc = nullptr;
    QPair<QLineEdit*, bool>* m_srcdir = nullptr;
    QPair<QLineEdit*, bool>* m_work = nullptr;
    QList<QPair<QLineEdit*, bool>*> m_rows;
    QJsonObject m_tmpl;
    bool m_workTouched = false, m_fileTouched = false, m_batch = false, m_xdcAuto = true;
    bool ask(const QString& q) { return m_batch || QMessageBox::question(this, "new project", q) == QMessageBox::Yes; }
    QString m_lastDir;

    static QString home(const QString& p) {  // store ~/... so projects move between accounts
        const QString h = QDir::homePath();
        return p.startsWith(h + "/") ? "~" + p.mid(h.size()) : p;
    }
    static QString unhome(const QString& p) { return p.startsWith("~/") ? QDir::homePath() + p.mid(1) : p; }
    QString lastDir() const { return m_lastDir.isEmpty() ? QDir::homePath() : m_lastDir; }
    QWidget* listWithButtons(QListWidget* list, const QList<QPair<QString, std::function<void()>>>& actions) {
        auto* w = new QWidget;
        auto* h = new QHBoxLayout(w);
        h->setContentsMargins(0, 0, 0, 0);
        h->addWidget(list, 1);
        auto* col = new QVBoxLayout;
        for (const auto& a : actions) {
            auto* b = new QPushButton(a.first);
            connect(b, &QPushButton::clicked, this, a.second);
            col->addWidget(b);
        }
        col->addStretch();
        h->addLayout(col);
        return w;
    }
    QPair<QLineEdit*, bool>* pathRow(QFormLayout* form, const QString& label, bool dir, const QString& filter) {
        auto* row = new QPair<QLineEdit*, bool>(new QLineEdit, dir);
        m_rows << row;
        auto* b = new QPushButton("Browse...");
        connect(b, &QPushButton::clicked, this, [this, row, label, filter] {
            const QString start = row->first->text().isEmpty() ? lastDir() : unhome(row->first->text());
            const QString r = row->second ? QFileDialog::getExistingDirectory(this, label, start)
                                          : QFileDialog::getOpenFileName(this, label, start, filter);
            if (r.isEmpty()) return;
            row->first->setText(r);
            if (row == m_work) m_workTouched = true;
            if (row == m_xdc) m_xdcAuto = false;
        });
        auto* h = new QHBoxLayout;
        h->addWidget(row->first);
        h->addWidget(b);
        form->addRow(label, h);
        return row;
    }
    static void addUnique(QListWidget* l, const QString& s) {
        for (int i = 0; i < l->count(); ++i)
            if (l->item(i)->text() == s) return;
        l->addItem(s);
    }
    static void move(QListWidget* l, int by) {
        const int r = l->currentRow(), t = r + by;
        if (r < 0 || t < 0 || t >= l->count()) return;
        l->insertItem(t, l->takeItem(r));
        l->setCurrentRow(t);
    }
    void loadTemplate() {
        QFile f(m_template->currentData().toString());
        if (!f.open(QIODevice::ReadOnly)) return;
        m_tmpl = QJsonDocument::fromJson(f.readAll()).object();
        auto join = [&](const char* k) {
            QStringList l;
            for (const auto& v : m_tmpl.value(k).toArray()) l << v.toString();
            return l.join(' ');
        };
        m_blackboxes->setText(join("blackboxes"));
        m_defines->setText(join("defines"));
        m_part->setText(m_tmpl.value("part").toString());
        m_tmpl.remove("sources");  // the design fields are the user's
        m_tmpl.remove("incdirs");
        m_tmpl.remove("xdc");
        m_tmpl.remove("srcdir");
    }
    void followName() {
        const QString n = m_name->text().trimmed();
        if (!m_workTouched) m_work->first->setText(n.isEmpty() ? QString() : QDir::homePath() + "/synthgui-work/" + n);
        if (!m_fileTouched) m_file->setText(n.isEmpty() ? QString() : projectsDir() + "/" + n + ".json");
    }
    void addFolder() {
        const QString d = QFileDialog::getExistingDirectory(this, "Add every HDL file in", lastDir());
        if (d.isEmpty()) return;
        QStringList l;
        for (const QString& f : QDir(d).entryList({"*.sv", "*.v"}, QDir::Files, QDir::Name)) l << QDir(d).filePath(f);
        addSources(l);
    }
    void addSources(const QStringList& files) {
        for (const QString& f : files) {
            const QFileInfo fi(f);
            m_lastDir = fi.absolutePath();
            if (fi.suffix() == "svh" || fi.suffix() == "vh") { addUnique(m_incdirs, fi.absolutePath()); continue; }  // headers are included, not compiled
            addUnique(m_sources, fi.absoluteFilePath());
            // a directory holding headers or memory images is likely needed as well
            const QDir d = fi.absoluteDir();
            if (!d.entryList({"*.svh", "*.vh"}, QDir::Files).isEmpty()) addUnique(m_incdirs, d.absolutePath());
            if (m_srcdir->first->text().isEmpty() && !d.entryList({"*.hex", "*.mem", "*.coe"}, QDir::Files).isEmpty())
                m_srcdir->first->setText(d.absolutePath());
        }
        if (m_srcdir->first->text().isEmpty() && m_sources->count()) m_srcdir->first->setText(QFileInfo(m_sources->item(0)->text()).absolutePath());
        guessTop();
    }
    // an .xdc beside the sources, preferring one named after the top and the open-flow (_open) variant
    void guessXdc() {
        if (!m_xdcAuto) return;
        QString best;
        int bestScore = -1;
        QSet<QString> dirs;
        for (int i = 0; i < m_sources->count(); ++i) dirs << QFileInfo(m_sources->item(i)->text()).absolutePath();
        const QString top = m_top->currentText();
        for (const QString& dn : dirs) {
            const QDir d(dn);
            for (const QString& x : d.entryList({"*.xdc"}, QDir::Files, QDir::Name)) {
                const int score = (!top.isEmpty() && x.startsWith(top) ? 4 : 0) + (x.contains("open") ? 2 : 0) + (x.contains(top.section('_', 0, 0)) ? 1 : 0);
                if (score > bestScore) { bestScore = score; best = d.filePath(x); }
            }
        }
        m_xdc->first->setText(best);
    }
    // modules declared in the sources; the top is one no other source instantiates
    void guessTop() {
        static const QRegularExpression decl("^\\s*module\\s+(\\w+)", QRegularExpression::MultilineOption);
        static const QRegularExpression comments("//[^\\n]*|/\\*.*?\\*/", QRegularExpression::DotMatchesEverythingOption);
        QStringList mods;
        QString all;
        for (int i = 0; i < m_sources->count(); ++i) {
            QFile f(m_sources->item(i)->text());
            if (!f.open(QIODevice::ReadOnly)) continue;
            const QString t = QString::fromUtf8(f.readAll()).remove(comments);
            all += t + "\n";
            auto it = decl.globalMatch(t);
            while (it.hasNext()) mods << it.next().captured(1);
        }
        QStringList tops;
        for (const QString& m : mods) {
            const QRegularExpression use("^\\s*" + m + "\\s*(#\\s*\\(|\\w+\\s*\\()", QRegularExpression::MultilineOption);
            if (!use.match(all).hasMatch()) tops << m;
        }
        const QString keep = m_top->currentText();
        m_top->clear();
        m_top->addItems(tops);  // likely tops first, then the rest
        for (const QString& m : mods)
            if (!tops.contains(m)) m_top->addItem(m);
        if (!keep.isEmpty() && mods.contains(keep)) m_top->setCurrentText(keep);
        else if (!tops.isEmpty()) m_top->setCurrentText(tops.last());  // the last uninstantiated module: usually the board top
    }
};

void openProjectWindow(const QString& file);

// ---------------------------------------------------------------- options

// One stage's options (options.h): a checkbox per option -- unchecked leaves
// the tool's own default -- with its value beside it, the options that change
// the quality of results first, and the command line they make.
class OptionsPanel final : public QWidget {
public:
    OptionsPanel(const QString& stage, const QString& tool, QMap<QString, QString>* on, std::function<void()> changed)
        : m_stage(stage), m_on(on), m_changed(std::move(changed)) {
        auto* lay = new QVBoxLayout(this);
        auto* qor = new QGroupBox("Quality of results");
        auto* other = new QGroupBox("Output");
        auto* warn = new QGroupBox("Warnings not reported");
        warn->setToolTip("Checked: the tool does not report this warning");
        auto* fq = new QFormLayout(qor);
        auto* fo = new QFormLayout(other);
        auto* fw = new QFormLayout(warn);
        bool anyWarning = false;
        // the value under its checkbox when the column is too narrow for both
        for (QFormLayout* f : {fq, fo, fw}) {
            f->setRowWrapPolicy(QFormLayout::WrapLongRows);
            f->setFieldGrowthPolicy(QFormLayout::AllNonFixedFieldsGrow);
        }
        for (const OptionSpec& s : optionSpecs()) {
            if (s.stage() != stage) continue;
            anyWarning |= s.isWarning();
            QFormLayout* form = s.isWarning() ? fw : s.qor ? fq : fo;
            auto* cb = new QCheckBox(s.label);
            const QString tip = QString(s.tip) + "\n\n" + s.flag;
            cb->setToolTip(tip);
            cb->setChecked(on->contains(s.key));
            QWidget* ed = editor(s);
            if (ed) {
                ed->setToolTip(tip);
                ed->setEnabled(cb->isChecked());
                form->addRow(cb, ed);
            } else {
                form->addRow(cb);
            }
            const QString key = s.key;
            connect(cb, &QCheckBox::toggled, this, [this, key, ed, s](bool checked) {
                if (ed) ed->setEnabled(checked);
                if (checked) (*m_on)[key] = ed ? m_value[key]() : "1";
                else m_on->remove(key);
                update();
            });
        }
        auto* extra = new QLineEdit(on->value(stage + ".extra"));
        extra->setToolTip("Passed to " + tool + " as typed, after the options above");
        connect(extra, &QLineEdit::editingFinished, this, [this, extra] {
            if (extra->text().trimmed().isEmpty()) m_on->remove(m_stage + ".extra");
            else (*m_on)[m_stage + ".extra"] = extra->text().trimmed();
            update();
        });
        fo->addRow("Additional flags", extra);
        m_line = new QPlainTextEdit;
        m_line->setReadOnly(true);
        m_line->setMaximumHeight(90);
        m_line->setToolTip("What " + tool + " is given, from the options above");
        lay->addWidget(qor);
        lay->addWidget(other);
        if (anyWarning) lay->addWidget(warn);
        else delete warn;
        lay->addWidget(new QLabel(tool + " command line"));
        lay->addWidget(m_line);
        lay->addStretch(1);
        m_line->setPlainText(optionArgs(m_stage, *m_on));
    }

private:
    QWidget* editor(const OptionSpec& s) {
        const QString key = s.key;
        const QString start = m_on->contains(key) ? m_on->value(key) : QString(s.def);
        auto set = [this, key](const QString& v) {
            if (m_on->contains(key) && m_on->value(key) != v) { (*m_on)[key] = v; update(); }
        };
        switch (s.kind) {
        case OptionSpec::Bool: return nullptr;
        case OptionSpec::Int: {
            auto* sb = new QSpinBox;
            sb->setRange(int(s.lo), int(std::min(s.hi, 2e9)));
            sb->setValue(start.toInt());
            m_value[key] = [sb] { return QString::number(sb->value()); };
            connect(sb, &QSpinBox::valueChanged, this, [set](int v) { set(QString::number(v)); });
            return sb;
        }
        case OptionSpec::Real: {
            auto* sb = new QDoubleSpinBox;
            sb->setRange(s.lo, s.hi);
            sb->setDecimals(2);
            sb->setValue(start.toDouble());
            m_value[key] = [sb] { return QString::number(sb->value()); };
            connect(sb, &QDoubleSpinBox::valueChanged, this, [set](double v) { set(QString::number(v)); });
            return sb;
        }
        case OptionSpec::Choice: {
            // editable: a value not on the list (a custom ABC script) is kept as typed
            auto* cb = new QComboBox;
            cb->setEditable(true);
            for (const auto& c : s.choiceList()) cb->addItem(c.second, c.first);
            const int at = cb->findData(start);
            if (at >= 0) cb->setCurrentIndex(at);
            else cb->setEditText(start);
            auto value = [cb] {
                const int i = cb->findText(cb->currentText());
                return i >= 0 ? cb->itemData(i).toString() : cb->currentText();
            };
            m_value[key] = value;
            connect(cb, &QComboBox::currentTextChanged, this, [set, value](const QString&) { set(value()); });
            return cb;
        }
        case OptionSpec::Text: {
            auto* le = new QLineEdit(start);
            m_value[key] = [le] { return le->text().trimmed(); };
            connect(le, &QLineEdit::editingFinished, this, [set, le] { set(le->text().trimmed()); });
            return le;
        }
        }
        return nullptr;
    }
    void update() {
        m_line->setPlainText(optionArgs(m_stage, *m_on));
        if (m_changed) m_changed();
    }

    QString m_stage;
    QMap<QString, QString>* m_on;
    std::function<void()> m_changed;
    QMap<QString, std::function<QString()>> m_value;
    QPlainTextEdit* m_line = nullptr;
};

// ---------------------------------------------------------------- built-in tools
// The converters in tools/ run inside this process, in a worker thread, with their output going to the step's log. A step's
// command names one as @name (the project variables {fasm2frames}, {bit2uf2}, {sta_prep}, {bram_fom} expand to that) and
// may chain it with && to other commands; the commands around it are run by bash as before, and a command that names
// none is passed to bash untouched.
namespace {

struct Piece {
    bool builtin;
    QString text;
    bool direct = false;  // run by this program without a shell (directPieces)
};

// the command's parts between && outside quotes and parentheses
QStringList andSegments(const QString& cmd) {
    QStringList segs;
    QString cur;
    QChar q;
    int depth = 0;
    bool backtick = false;
    const int n = cmd.size();
    for (int i = 0; i < n; i++) {
        const QChar c = cmd[i];
        if (q == '\'') { cur += c; if (c == '\'') q = QChar(); continue; }
        if (q == '"') {
            cur += c;
            if (c == '\\' && i + 1 < n) cur += cmd[++i];
            else if (c == '"') q = QChar();
            continue;
        }
        if (c == '\\' && i + 1 < n) { cur += c; cur += cmd[++i]; continue; }
        if (c == '\'' || c == '"') { q = c; cur += c; continue; }
        if (c == '`') backtick = !backtick;
        if (c == '(') depth++;
        if (c == ')' && depth > 0) depth--;
        if (c == '&' && i + 1 < n && cmd[i + 1] == '&' && depth == 0 && !backtick) { segs << cur; cur.clear(); i++; continue; }
        cur += c;
    }
    segs << cur;
    return segs;
}

bool isBuiltin(const QString& s) { return s.size() > 1 && s[0] == '@' && s[1].isLetter(); }

// consecutive ordinary commands stay together so `cd x && prog` still works
QList<Piece> splitPieces(const QString& cmd) {
    const QStringList segs = andSegments(cmd);
    bool any = false;
    for (const QString& s : segs) any |= isBuiltin(s.trimmed());
    if (!any) return {{false, cmd}};
    QList<Piece> out;
    QStringList shell;
    auto flush = [&] { if (!shell.isEmpty()) { out.append({false, shell.join(" && ")}); shell.clear(); } };
    for (const QString& s : segs) {
        const QString t = s.trimmed();
        if (isBuiltin(t)) { flush(); out.append({true, t}); }
        else shell << t;
    }
    flush();
    return out;
}

// words the way a shell reads them (quotes and backslashes; no expansion)
QStringList shellWords(const QString& s) {
    QStringList out;
    QString cur;
    bool have = false;
    QChar q;
    for (int i = 0; i < s.size(); i++) {
        const QChar c = s[i];
        if (q == '\'') { if (c == '\'') q = QChar(); else cur += c; }
        else if (q == '"') {
            if (c == '"') q = QChar();
            else if (c == '\\' && i + 1 < s.size() && QString("\"\\$`").contains(s[i + 1])) cur += s[++i];
            else cur += c;
        }
        else if (c == '\'' || c == '"') { q = c; have = true; }
        else if (c == '\\' && i + 1 < s.size()) { cur += s[++i]; have = true; }
        else if (c.isSpace()) { if (have || !cur.isEmpty()) { out << cur; cur.clear(); have = false; } }
        else { cur += c; have = true; }
    }
    if (have || !cur.isEmpty()) out << cur;
    return out;
}

// words, quotes and VAR=value only: nothing a shell would expand, redirect or pipe
bool plainSegment(const QString& s) {
    QChar q;
    for (int i = 0; i < s.size(); i++) {
        const QChar c = s[i];
        if (q == '\'') { if (c == '\'') q = QChar(); continue; }
        if (c == '\\' && i + 1 < s.size()) { i++; continue; }
        if (q == '"') {
            if (c == '"') q = QChar();
            else if (c == '$' || c == '`') return false;
            continue;
        }
        if (c == '\'' || c == '"') { q = c; continue; }
        if (QString("|;<>&`$()*?[]~#!").contains(c)) return false;
    }
    return q.isNull();
}

// The step as pieces this program runs itself, one per && part (MainWindow::runDirect), or nothing when some part needs a
// shell.  The project commands use no more than this, so on Windows the flow needs no bash.
QList<Piece> directPieces(const QString& cmd) {
    QList<Piece> out;
    for (const QString& s : andSegments(cmd)) {
        const QString t = s.trimmed();
        if (isBuiltin(t)) out.append({true, t});
        else if (!t.isEmpty() && plainSegment(t)) out.append({false, t, true});
        else return {};
    }
    return out;
}

// run a built-in tool by name; its output goes to the calling thread's toolio sink
int runBuiltinTool(const QString& name, const QStringList& args) {
    int (*fn)(int, char**) = nullptr;
    if (name == "fasm2frames") fn = fasm2frames_main;
    else if (name == "bit2uf2") fn = bit2uf2_main;
    else if (name == "sta-prep") fn = sta_prep_main;
    else if (name == "bram-fom") fn = bram_fom_main;
    if (!fn) {
        toolio::err("synthgui: no built-in tool '%s'\n", name.toLocal8Bit().constData());
        return 127;
    }
    std::vector<QByteArray> store{name.toLocal8Bit()};
    for (const QString& a : args) store.push_back(a.toLocal8Bit());
    std::vector<char*> argv;
    for (auto& s : store) argv.push_back(s.data());
    argv.push_back(nullptr);
    try {
        return fn((int)store.size(), argv.data());
    } catch (const toolio::Exit& e) {
        return e.code;
    } catch (const std::exception& e) {
        toolio::err("synthgui: %s: %s\n", name.toLocal8Bit().constData(), e.what());
        return 1;
    }
}

}  // namespace

// ---------------------------------------------------------------- settings
// Per user, not per project. SYNTHGUI_SETTINGS=file.ini keeps them in that file instead (for scripts and tests).
namespace {

QSettings appSettings() {
    const QString file = qEnvironmentVariable("SYNTHGUI_SETTINGS");
    return file.isEmpty() ? QSettings() : QSettings(file, QSettings::IniFormat);
}
// Run all (and --run all) write non-volatile memory only when this is on; it is off until somebody turns it on
bool writeNonVolatileOnRunAll() { return appSettings().value("uf2/writeOnRunAll", false).toBool(); }
void setWriteNonVolatileOnRunAll(bool on) { appSettings().setValue("uf2/writeOnRunAll", on); }

class SettingsDialog final : public QDialog {
public:
    explicit SettingsDialog(QWidget* parent = nullptr) : QDialog(parent) {
        setWindowTitle("Settings");
        auto* v = new QVBoxLayout(this);
        auto* box = new QGroupBox("UF2 targets (non-volatile)");
        auto* bl = new QVBoxLayout(box);
        write = new QCheckBox("Write the UF2 to the board when Run all is pressed");
        write->setChecked(writeNonVolatileOnRunAll());
        auto* note = new QLabel(
            "Off by default. A UF2 target copies the bitstream to the board's USB drive (the Sonata's SONATA drive), "
            "where the board's own firmware writes it to non-volatile flash, so it is what the board boots from after a "
            "power cycle.\n\nWith this off, Run all leaves those steps out and says so; their own buttons in the toolbar "
            "always work. The JTAG Program step loads the FPGA's volatile configuration and is not affected.");
        note->setWordWrap(true);
        bl->addWidget(write);
        bl->addWidget(note);
        v->addWidget(box);
        auto* buttons = new QDialogButtonBox(QDialogButtonBox::Ok | QDialogButtonBox::Cancel);
        connect(buttons, &QDialogButtonBox::accepted, this, [this] { save(); accept(); });
        connect(buttons, &QDialogButtonBox::rejected, this, &QDialog::reject);
        v->addWidget(buttons);
        setMinimumWidth(480);
    }
    void save() { setWriteNonVolatileOnRunAll(write->isChecked()); }
    QCheckBox* write = nullptr;
};

}  // namespace

class MainWindow final : public QMainWindow {
public:
    ~MainWindow() override {
        if (m_toolThread) {            // a built-in tool is still running: let it finish
            m_toolThread->wait();
            delete m_toolThread;
        }
    }
    explicit MainWindow(Project p) : m_p(std::move(p)) {
        setWindowTitle("synthgui - " + m_p.name);
        resize(1500, 950);
        QDir().mkpath(m_p.work);

        // files
        m_files = new QTreeWidget;
        m_files->setHeaderLabel(m_p.name);
        auto* srcItem = new QTreeWidgetItem(m_files, QStringList("Sources"));
        for (const QString& s : m_p.sources) addFile(srcItem, s);
        if (!m_p.xdc.isEmpty()) addFile(new QTreeWidgetItem(m_files, QStringList("Constraints")), m_p.xdc);
        m_files->expandAll();
        connect(m_files, &QTreeWidget::itemDoubleClicked, this, [this](QTreeWidgetItem* it) {
            const QString f = it->data(0, Qt::UserRole).toString();
            if (!f.isEmpty()) openFile(f, 0);
        });

        // editors
        m_editors = new QTabWidget;
        m_editors->setTabsClosable(true);
        connect(m_editors, &QTabWidget::tabCloseRequested, this, [this](int i) {
            auto* ed = qobject_cast<QPlainTextEdit*>(m_editors->widget(i));
            if (ed && !confirmUnsaved({ed}, "closing it")) return;
            m_editors->removeTab(i);
            delete ed;
        });
        auto* save = new QShortcut(QKeySequence::Save, this);
        connect(save, &QShortcut::activated, this, [this] { saveCurrent(); });

        // results
        m_results = new QTabWidget;
        m_area = new QTableWidget(0, 4);
        m_area->setHorizontalHeaderLabels({"Cell", "Count", "Device", "Use"});
        m_area->horizontalHeader()->setStretchLastSection(true);
        m_timing = new QTableWidget(0, 4);
        m_timing->setHorizontalHeaderLabels({"Clock", "Fmax (MHz)", "Target (MHz)", "Status"});
        m_timing->horizontalHeader()->setStretchLastSection(true);
        m_chip = new ChipView;
        m_legend = new QLabel;
        m_legend->setStyleSheet("QLabel { background: #1b1d22; color: #dddddd; padding: 6px; }");
        m_legend->setAlignment(Qt::AlignTop);
        auto* chipPanel = new QSplitter;
        chipPanel->addWidget(m_chip);
        chipPanel->addWidget(m_legend);
        chipPanel->setStretchFactor(0, 1);
        m_pathClock = new QComboBox;
        m_path = new QTableWidget(0, 5);
        m_path->setHorizontalHeaderLabels({"Type", "Delay (ns)", "Total (ns)", "Cell / net", "From -> to"});
        m_path->horizontalHeader()->setStretchLastSection(true);
        m_path->setSelectionBehavior(QAbstractItemView::SelectRows);
        auto* pathPanel = new QWidget;
        auto* pl = new QVBoxLayout(pathPanel);
        pl->setContentsMargins(0, 0, 0, 0);
        pl->addWidget(m_pathClock);
        pl->addWidget(m_path);
        connect(m_pathClock, &QComboBox::currentTextChanged, this, [this](const QString& c) { showPath(c); });
        connect(m_path, &QTableWidget::cellDoubleClicked, this, [this](int r, int) {
            const QString cell = m_path->item(r, 0)->data(Qt::UserRole).toString();
            const QPointF at = m_path->item(r, 0)->data(Qt::UserRole + 1).toPointF();
            m_results->setCurrentWidget(m_chipPanel);
            m_chip->focus(cell, at);
        });
        m_problems = new QListWidget;
        connect(m_problems, &QListWidget::itemDoubleClicked, this, [this](QListWidgetItem* it) {
            const QString f = it->data(Qt::UserRole).toString();
            if (!f.isEmpty()) openFile(f, it->data(Qt::UserRole + 1).toInt());
        });
        // Log: the steps down the left, coloured by their last result, each
        // with its own output -- a step's log stays put while another runs
        QFont mono("Monospace");
        mono.setStyleHint(QFont::TypeWriter);
        m_logList = new QListWidget;
        m_logStack = new QStackedWidget;
        for (const Step& st : m_p.steps) {
            auto* ed = new QPlainTextEdit;
            ed->setReadOnly(true);
            ed->setMaximumBlockCount(20000);
            ed->setFont(mono);
            m_logs[st.id] = ed;
            m_logStack->addWidget(ed);
            auto* it = new QListWidgetItem(st.label, m_logList);
            it->setData(Qt::UserRole, st.id);
            it->setForeground(QColor(0x60, 0x60, 0x60));
        }
        m_logList->setMaximumWidth(m_logList->sizeHintForColumn(0) + 24);
        connect(m_logList, &QListWidget::currentRowChanged, m_logStack, &QStackedWidget::setCurrentIndex);
        m_logPanel = new QWidget;
        auto* logLayout = new QHBoxLayout(m_logPanel);
        logLayout->setContentsMargins(0, 0, 0, 0);
        logLayout->setSpacing(0);
        logLayout->addWidget(m_logList);
        logLayout->addWidget(m_logStack, 1);
        m_results->addTab(m_logPanel, "Log");
        m_results->addTab(m_area, "Area");
        m_results->addTab(m_timing, "Timing");
        m_results->addTab(chipPanel, "Chip");
        m_results->addTab(pathPanel, "Critical path");
        m_pathPanel = pathPanel;
        m_chipPanel = chipPanel;
        m_results->addTab(m_problems, "Problems");

        auto* right = new QSplitter(Qt::Vertical);
        right->addWidget(m_editors);
        right->addWidget(m_results);
        right->setSizes({450, 500});
        // left: the files, and the options of the steps that take them
        auto* side = m_side = new QTabWidget;
        side->addTab(m_files, "Files");
        auto optionsTab = [this, side](const QString& stage, const QString& tool, const QString& title) {
            auto* scroll = new QScrollArea;
            scroll->setWidgetResizable(true);
            scroll->setWidget(new OptionsPanel(stage, tool, &m_p.options, [this] { optionsChanged(); }));
            side->addTab(scroll, title);
        };
        optionsTab("synth", "Verilator", "Synthesis");
        optionsTab("pnr", "nextpnr", "Place && route");
        auto* split = new QSplitter;
        split->addWidget(side);
        split->addWidget(right);
        split->setSizes({380, 1120});
        setCentralWidget(split);

        // Settings: the standard Preferences item on macOS (the application menu, Cmd+,), File > Settings... elsewhere
        auto* prefs = new QAction("Settings...", this);
        prefs->setMenuRole(QAction::PreferencesRole);
        prefs->setShortcut(QKeySequence::Preferences);
        connect(prefs, &QAction::triggered, this, [this] { SettingsDialog(this).exec(); });
        menuBar()->addMenu("&File")->addAction(prefs);

        // pipeline
        auto* tb = addToolBar("Flow");
        for (const Step& s : m_p.steps) {
            QAction* a = tb->addAction(s.label, this, [this, s] { runSteps({s}); });
            a->setToolTip(m_p.expand(s.command));
            m_stepAction[s.id] = a;
            m_stepStatus[s.id] = new QLabel(" " + s.label + ": - ");
            statusBar()->addPermanentWidget(m_stepStatus[s.id]);
        }
        tb->addSeparator();
        tb->addAction("Run all", this, [this] {
            QStringList left;
            const QList<Step> steps = runAllSteps(&left);
            if (!left.isEmpty())
                statusBar()->showMessage("Run all leaves out " + left.join(", ") + " (writes non-volatile memory; Settings... turns it on)", 12000);
            runSteps(steps);
        });
        tb->addAction("Stop", this, [this] { stop(); });
        tb->addAction("Reload results", this, [this] { refreshAll(); });
        tb->addSeparator();
        tb->addAction("New project...", this, [this] {
            NewProjectDialog d(this);
            if (d.exec() == QDialog::Accepted) openProjectWindow(d.created);
        });
        tb->addAction("Open project...", this, [this] {
            const QString f = QFileDialog::getOpenFileName(this, "Open project", QFileInfo(m_p.path).absolutePath(), "synthgui project (*.json)");
            if (!f.isEmpty()) openProjectWindow(f);
        });

        if (!m_p.sources.isEmpty()) openFile(m_p.sources.last(), 0);
        // the last run of each step, from <work>/<step>.status (exit code, seconds) or just its log
        for (const Step& s : m_p.steps) {
            QFile st(m_p.work + "/" + s.id + ".status");
            const QFileInfo lf(m_p.logPath(s.id));
            if (st.open(QIODevice::ReadOnly)) {
                const QStringList f = QString::fromUtf8(st.readAll()).split(' ');
                const bool ok = f.value(0).trimmed() == "0";
                setStepState(s.id, QString(" %1: %2 (%3 s, %4) ").arg(s.label, ok ? "ok" : "FAILED", f.value(1).trimmed(), lf.lastModified().toString("dd MMM hh:mm")),
                             ok ? "#208020" : "#c02020");
            } else if (lf.exists()) {
                setStepState(s.id, QString(" %1: log of %2 ").arg(s.label, lf.lastModified().toString("dd MMM hh:mm")), "#606060");
            }
            loadLog(s.id);
        }
        if (!m_p.steps.isEmpty()) m_logList->setCurrentRow(0);
        refreshAll();
    }

    // render one view for --screenshot
    QWidget* view(const QString& name) {
        if (name == "area") { m_results->setCurrentWidget(m_area); return this; }
        if (name == "timing") { m_results->setCurrentWidget(m_timing); return this; }
        if (name == "log") { m_results->setCurrentWidget(m_logPanel); return this; }
        if (name == "problems") { m_results->setCurrentWidget(m_problems); return this; }
        if (name == "path") { m_results->setCurrentWidget(m_pathPanel); return this; }
        if (name == "synthesis") { m_side->setCurrentIndex(1); return this; }
        if (name == "pnr") { m_side->setCurrentIndex(2); return this; }
        m_results->setCurrentWidget(m_chipPanel);
        return this;
    }
    void fitChip() { m_chip->fit(); }

protected:
    void closeEvent(QCloseEvent* e) override {
        if (confirmUnsaved(dirtyEditors(), "closing the project")) e->accept();
        else e->ignore();
    }

public:
    // the steps of Run all: every step, except non-volatile ones unless Settings has them on (left gets the labels of those)
    QList<Step> runAllSteps(QStringList* left = nullptr) const {
        const bool nv = writeNonVolatileOnRunAll();
        QList<Step> r;
        for (const Step& s : m_p.steps) {
            if (s.nonvolatile && !nv) { if (left) *left << s.label; continue; }
            r << s;
        }
        return r;
    }
    // batch: run these steps (ids, or "all"), then call done(ok)
    void runThen(const QStringList& ids, std::function<void(bool)> done) {
        QList<Step> steps;
        QStringList left;
        const QList<Step> all = runAllSteps(&left);
        for (const Step& s : m_p.steps)
            if (ids.contains(s.id) || (ids.contains("all") && all.contains(s))) steps << s;
        if (ids.contains("all") && !left.isEmpty())
            fprintf(stderr, "synthgui: --run all leaves out %s (writes non-volatile memory; Settings turns it on, or name the step)\n",
                    qPrintable(left.join(", ")));
        m_done = std::move(done);
        runSteps(steps);
    }
    // select a step's page in the Log tab
    void showLog(const QString& stepId) {
        for (int i = 0; i < m_logList->count(); ++i)
            if (m_logList->item(i)->data(Qt::UserRole).toString() == stepId) m_logList->setCurrentRow(i);
    }

private:
    // a step's last log, read into its page
    void loadLog(const QString& stepId) {
        QPlainTextEdit* ed = m_logs.value(stepId);
        QFile f(m_p.logPath(stepId));
        if (!ed || !f.open(QIODevice::ReadOnly)) return;
        ed->setPlainText(QString::fromLocal8Bit(f.readAll()).right(60000));
        ed->moveCursor(QTextCursor::End);  // where the step's result is
    }
    // a step's state, on the status bar and on its entry in the Log tab's list
    void setStepState(const QString& stepId, const QString& text, const char* colour) {
        if (QLabel* l = m_stepStatus.value(stepId)) {
            l->setText(text);
            l->setStyleSheet(QString("color: ") + colour);
        }
        for (int i = 0; i < m_logList->count(); ++i) {
            QListWidgetItem* it = m_logList->item(i);
            if (it->data(Qt::UserRole).toString() == stepId) it->setForeground(QColor(colour));
        }
    }
    void addFile(QTreeWidgetItem* parent, const QString& f) {
        auto* it = new QTreeWidgetItem(parent, QStringList(QFileInfo(f).fileName()));
        it->setData(0, Qt::UserRole, f);
        it->setToolTip(0, f);
    }
    void openFile(const QString& f, int line) {
        for (int i = 0; i < m_editors->count(); ++i) {
            if (m_editors->widget(i)->property("file").toString() == f) {
                m_editors->setCurrentIndex(i);
                gotoLine(qobject_cast<QPlainTextEdit*>(m_editors->widget(i)), line);
                return;
            }
        }
        QFile file(f);
        if (!file.open(QIODevice::ReadOnly)) return;
        auto* ed = new QPlainTextEdit;
        QFont mono("Monospace");
        mono.setStyleHint(QFont::TypeWriter);
        ed->setFont(mono);
        ed->setLineWrapMode(QPlainTextEdit::NoWrap);
        ed->setPlainText(QString::fromUtf8(file.readAll()));
        ed->setProperty("file", f);
        ed->document()->setModified(false);
        // "*" on the tab while the text differs from the file
        connect(ed->document(), &QTextDocument::modificationChanged, this, [this, ed](bool dirty) {
            const int i = m_editors->indexOf(ed);
            if (i >= 0) m_editors->setTabText(i, (dirty ? "*" : "") + QFileInfo(ed->property("file").toString()).fileName());
        });
        new HdlHighlighter(ed->document(), f.endsWith(".xdc"));
        m_editors->setCurrentIndex(m_editors->addTab(ed, QFileInfo(f).fileName()));
        m_editors->setTabToolTip(m_editors->currentIndex(), f);
        gotoLine(ed, line);
    }
    static void gotoLine(QPlainTextEdit* ed, int line) {
        if (!ed || line <= 0) return;
        QTextCursor c(ed->document()->findBlockByNumber(line - 1));
        ed->setTextCursor(c);
        ed->centerCursor();
    }
    void saveCurrent() {
        if (auto* ed = qobject_cast<QPlainTextEdit*>(m_editors->currentWidget())) save(ed);
    }
    bool save(QPlainTextEdit* ed) {
        QFile f(ed->property("file").toString());
        if (!f.open(QIODevice::WriteOnly) || f.write(ed->toPlainText().toUtf8()) < 0) {
            QMessageBox::critical(this, "synthgui", "Cannot save " + f.fileName() + ": " + f.errorString());
            return false;
        }
        ed->document()->setModified(false);
        statusBar()->showMessage("saved " + f.fileName(), 3000);
        return true;
    }
    QList<QPlainTextEdit*> dirtyEditors() const {
        QList<QPlainTextEdit*> r;
        for (int i = 0; i < m_editors->count(); ++i)
            if (auto* ed = qobject_cast<QPlainTextEdit*>(m_editors->widget(i)); ed && ed->document()->isModified()) r << ed;
        return r;
    }
    // Save, discard or cancel before `what`; false means cancel.  The flow
    // reads the files on disk, so a build after Discard ignores the edits.
    bool confirmUnsaved(const QList<QPlainTextEdit*>& eds, const QString& what) {
        QList<QPlainTextEdit*> dirty;
        for (auto* ed : eds) if (ed->document()->isModified()) dirty << ed;
        if (dirty.isEmpty()) return true;
        QStringList names;
        for (auto* ed : dirty) names << QFileInfo(ed->property("file").toString()).fileName();
        const auto b = QMessageBox::warning(this, "synthgui",
            QString("Unsaved changes in %1.\nSave before %2?").arg(names.join(", "), what),
            QMessageBox::SaveAll | QMessageBox::Discard | QMessageBox::Cancel, QMessageBox::SaveAll);
        if (b == QMessageBox::Cancel) return false;
        if (b == QMessageBox::SaveAll)
            for (auto* ed : dirty) if (!save(ed)) return false;
        return true;
    }

    // An option changed in a panel: the commands follow it, and so does the
    // project file, so a batch run (--run) builds what the panels show
    void optionsChanged() {
        m_p.applyOptions();
        for (const Step& s : m_p.steps)
            if (m_stepAction.contains(s.id)) m_stepAction[s.id]->setToolTip(m_p.expand(s.command));
        QString err;
        if (!m_p.saveOptions(err)) statusBar()->showMessage("options not saved: " + err, 5000);
    }

    // ---- running the flow
    void runSteps(QList<Step> steps) {
        if (m_proc || m_toolThread) return;
        if (!confirmUnsaved(dirtyEditors(), "building")) return;
        m_queue = steps;
        next();
    }
    void next() {
        if (m_queue.isEmpty()) {
            refreshAll();
            if (m_done) { auto d = m_done; m_done = nullptr; d(true); }
            return;
        }
        const Step s = m_queue.takeFirst();
        m_cur = s;
        const QString cmd = m_p.expand(s.command);
        m_curLog = m_logs.value(s.id);
        m_curLog->clear();
        showLog(s.id);
        m_results->setCurrentWidget(m_logPanel);
        m_curLog->appendPlainText("$ " + cmd + "\n");
        m_logFile.setFileName(m_p.logPath(s.id));
        m_logFile.open(QIODevice::WriteOnly | QIODevice::Truncate);
        setStepState(s.id, " " + s.label + ": running ", "#b07000");
        m_t0 = QDateTime::currentMSecsSinceEpoch();
        m_pieces = splitPieces(cmd);
#ifdef Q_OS_WIN
        // without a shell when the command allows it: then the flow needs no bash (and no MSYS) at all
        m_cwd = m_p.work;
        if (const QList<Piece> d = directPieces(cmd); !d.isEmpty()) m_pieces = d;
#endif
        runPiece();
    }
    void appendLog(const QByteArray& b) {
        m_logFile.write(b);
        m_logFile.flush();  // the file is read while the step runs (batch mode, tail -f)
        m_curLog->moveCursor(QTextCursor::End);
        m_curLog->insertPlainText(QString::fromLocal8Bit(b));
        m_curLog->moveCursor(QTextCursor::End);
    }
    // the next piece of the step's command: a built-in tool in this process, or commands for bash
    void runPiece() {
        if (m_pieces.isEmpty()) { finishStep(0); return; }
        const Piece p = m_pieces.takeFirst();
        if (p.builtin) runBuiltin(p.text);
        else if (p.direct) runDirect(p.text);
        else runShell(p.text);
    }
    void pieceDone(int code) {
        if (code || m_pieces.isEmpty()) finishStep(code);
        else runPiece();
    }
    void runShell(const QString& cmd) {
        m_proc = new QProcess(this);
        m_proc->setProcessChannelMode(QProcess::MergedChannels);
        m_proc->setWorkingDirectory(m_p.work);
        connect(m_proc, &QProcess::readyRead, this, [this] { appendLog(m_proc->readAll()); });
        connect(m_proc, qOverload<int, QProcess::ExitStatus>(&QProcess::finished), this, [this](int code, QProcess::ExitStatus) {
            m_proc->deleteLater();
            m_proc = nullptr;
            pieceDone(code);
        });
        m_proc->setProcessEnvironment(toolEnvironment());
        m_proc->start(bashPath(), {"-c", cmd});
    }
    static QProcessEnvironment toolEnvironment() {
        QProcessEnvironment env = Project::bundled() ? Project::bundledEnvironment() : QProcessEnvironment::systemEnvironment();
#ifdef Q_OS_WIN
        // The tools are MINGW64 programs (scripts/build-deps.sh).  scripts/package-windows.sh puts their DLLs beside them;
        // run from the checkout they come from MSYS2 (MSYS2_ROOT if not C:/msys64).
        const QString mingw = QDir::toNativeSeparators(env.value("MSYS2_ROOT", "C:/msys64") + "/mingw64/bin");
        if (QFileInfo::exists(mingw)) env.insert("PATH", mingw + ";" + env.value("PATH"));
#endif
        return env;
    }
    // one && part of a step (directPieces): VAR=value prefixes, then cd, mkdir [-p], cp or sync done here, or a program
    // started without a shell, in the directory the step has cd'd to
    void runDirect(const QString& text) {
        QStringList w = shellWords(text);
        QProcessEnvironment env = toolEnvironment();
        static const QRegularExpression assign("^[A-Za-z_][A-Za-z0-9_]*=");
        while (!w.isEmpty() && assign.match(w[0]).hasMatch()) {
            const int eq = w[0].indexOf('=');
            env.insert(w[0].left(eq), w[0].mid(eq + 1));
            w.removeFirst();
        }
        auto path = [this](const QString& p) { return QDir(m_cwd).absoluteFilePath(p); };
        auto fail = [this](const QString& msg) { appendLog((msg + "\n").toLocal8Bit()); pieceDone(1); };
        if (w.isEmpty()) { pieceDone(0); return; }
        const QString prog = w.takeFirst();
        if (prog == "cd") {
            const QString d = path(w.value(0, QDir::homePath()));
            if (!QFileInfo(d).isDir()) return fail("cd: " + d + ": no such directory");
            m_cwd = d;
            pieceDone(0);
            return;
        }
        if (prog == "mkdir") {
            for (const QString& a : w)
                if (a != "-p" && !QDir().mkpath(path(a))) return fail("mkdir: cannot create " + path(a));
            pieceDone(0);
            return;
        }
        if (prog == "cp") {
            if (w.size() < 2) return fail("cp: missing operand");
            const QString dst = path(w.takeLast());
            for (const QString& s : w) {
                const QString to = QFileInfo(dst).isDir() ? QDir(dst).filePath(QFileInfo(s).fileName()) : dst;
                QFile::remove(to);
                if (!QFile::copy(path(s), to)) return fail("cp: cannot copy " + path(s) + " to " + to);
            }
            pieceDone(0);
            return;
        }
        if (prog == "sync" || prog == "true") { pieceDone(0); return; }
        // a path as the step wrote it (CreateProcess adds .exe), or a name looked up on the tools' PATH
        QString exe = prog.contains('/') || prog.contains('\\') ? path(prog)
                    : QStandardPaths::findExecutable(prog, env.value("PATH").split(QDir::listSeparator(), Qt::SkipEmptyParts));
        if (exe.isEmpty()) return fail(prog + ": command not found");
        m_proc = new QProcess(this);
        m_proc->setProcessChannelMode(QProcess::MergedChannels);
        m_proc->setWorkingDirectory(m_cwd);
        m_proc->setProcessEnvironment(env);
        connect(m_proc, &QProcess::readyRead, this, [this] { appendLog(m_proc->readAll()); });
        connect(m_proc, qOverload<int, QProcess::ExitStatus>(&QProcess::finished), this, [this](int code, QProcess::ExitStatus) {
            m_proc->deleteLater();
            m_proc = nullptr;
            pieceDone(code);
        });
        connect(m_proc, &QProcess::errorOccurred, this, [this, exe](QProcess::ProcessError e) {
            if (e != QProcess::FailedToStart) return;  // anything else ends in finished()
            m_proc->deleteLater();
            m_proc = nullptr;
            appendLog((exe + ": cannot run\n").toLocal8Bit());
            pieceDone(127);
        });
        m_proc->start(exe, w);
    }
    static QString bashPath() {
#ifdef Q_OS_WIN
        // bash from Git for Windows or MSYS2; System32\bash.exe is the WSL launcher, which sees other paths
        for (const QString& dir : qEnvironmentVariable("PATH").split(';', Qt::SkipEmptyParts)) {
            const QString exe = QDir(dir).filePath("bash.exe");
            if (QFileInfo(exe).isExecutable() && !QDir::cleanPath(dir).endsWith("/System32", Qt::CaseInsensitive))
                return exe;
        }
        // Git for Windows puts only git.exe on the PATH (Git\cmd); bash is in Git\bin
        const QString git = QStandardPaths::findExecutable("git");
        if (!git.isEmpty()) {
            const QString exe = QFileInfo(git).dir().filePath("../bin/bash.exe");
            if (QFileInfo::exists(exe)) return QDir::cleanPath(exe);
        }
        return "bash";
#else
        return "/bin/bash";
#endif
    }
    // a worker thread runs the tool; what it prints is posted to this thread, in order, ahead of its result
    void runBuiltin(const QString& text) {
        const QStringList words = shellWords(text);
        const QString name = words.value(0).mid(1).replace('_', '-');
        const QStringList args = words.mid(1);
        struct LogSink : toolio::Sink {
            MainWindow* w;
            void write(bool, const char* d, size_t n) override {
                const QByteArray b(d, (qsizetype)n);
                MainWindow* win = w;
                QMetaObject::invokeMethod(win, [win, b] { win->appendLog(b); }, Qt::QueuedConnection);
            }
        };
        m_toolThread = QThread::create([this, name, args] {
            LogSink sink;
            sink.w = this;
            toolio::sink = &sink;
            const int code = runBuiltinTool(name, args);
            toolio::sink = nullptr;
            QMetaObject::invokeMethod(this, [this, code] {
                m_toolThread->wait();
                delete m_toolThread;
                m_toolThread = nullptr;
                pieceDone(code);
            }, Qt::QueuedConnection);
        });
        m_toolThread->start();
    }
    void finishStep(int code) {
        m_logFile.close();
        const double secs = (QDateTime::currentMSecsSinceEpoch() - m_t0) / 1000.0;
        setStepState(m_cur.id, QString(" %1: %2 (%3 s) ").arg(m_cur.label, code ? "FAILED" : "ok").arg(secs, 0, 'f', 0),
                     code ? "#c02020" : "#208020");
        QFile st(m_p.work + "/" + m_cur.id + ".status");
        if (st.open(QIODevice::WriteOnly)) st.write(QString("%1 %2\n").arg(code).arg(secs, 0, 'f', 0).toUtf8());
        refreshAll();
        if (code) {
            m_queue.clear();
            m_results->setCurrentWidget(m_problems);
            if (m_done) { auto d = m_done; m_done = nullptr; d(false); }
            return;
        }
        next();
    }
    void stop() {
        m_queue.clear();
        m_pieces.clear();                      // a built-in tool in a worker thread is let finish; nothing follows it
        if (m_proc) m_proc->kill();
    }

    // ---- results from the tools' output
    static QString readAll(const QString& f) {
        QFile file(f);
        return file.open(QIODevice::ReadOnly) ? QString::fromLocal8Bit(file.readAll()) : QString();
    }
    void refreshAll() {
        refreshArea();
        const QSet<QString> hot = refreshTiming();
        QString summary;
        m_chip->load(m_p.vars["placement"], hot, summary);
        m_legend->setText(m_chip->legendHtml());
        showPath(m_pathClock->currentText());  // the overlay goes on the freshly loaded plot
        m_results->setTabText(m_results->indexOf(m_chipPanel), "Chip (" + summary.section(',', 0, 0) + ")");
        refreshProblems();
    }
    void refreshArea() {
        m_area->setRowCount(0);
        // "%Info: map: LUT6=11372 FDRE=3101 ..." from the synthesis step
        const QString syn = readAll(m_p.logPath("synth"));
        static const QRegularExpression info("%Info: map:((?: \\w+=\\d+)+)");
        QMap<QString, int> cells;
        auto m = info.match(syn);
        if (m.hasMatch())
            for (const QString& kv : m.captured(1).split(' ', Qt::SkipEmptyParts)) cells[kv.section('=', 0, 0)] = kv.section('=', 1).toInt();
        // grouped estimate against the device
        QMap<QString, int> group;
        for (auto it = cells.begin(); it != cells.end(); ++it) {
            const QString k = it.key();
            const QString g = k.startsWith("LUT") ? "LUT" : k.startsWith("FD") ? "FF" : k.startsWith("RAMB") ? "RAMB36" : k.startsWith("RAM") ? "LUTRAM" : k.startsWith("DSP") ? "DSP" : k.contains("BUFG") ? "BUFG" : (k.contains("BUF") ? "IO" : k);
            group[g] += it.value() * (k.startsWith("RAMB18") ? 1 : 1);
        }
        auto row = [&](const QString& name, int n, int cap, bool bold) {
            const int r = m_area->rowCount();
            m_area->insertRow(r);
            auto* a = new QTableWidgetItem(name);
            QFont f = a->font();
            f.setBold(bold);
            a->setFont(f);
            m_area->setItem(r, 0, a);
            m_area->setItem(r, 1, new QTableWidgetItem(QString::number(n)));
            m_area->setItem(r, 2, new QTableWidgetItem(cap ? QString::number(cap) : QString()));
            auto* u = new QTableWidgetItem(cap ? QString("%1 %").arg(100.0 * n / cap, 0, 'f', 1) : QString());
            if (cap && n > cap) u->setForeground(QColor(0xc0, 0x20, 0x20));
            m_area->setItem(r, 3, u);
        };
        for (auto it = group.begin(); it != group.end(); ++it) row(it.key(), it.value(), m_p.capacity.value(it.key()), true);
        for (auto it = cells.begin(); it != cells.end(); ++it) row("   " + it.key(), it.value(), 0, false);
        // after place and route: nextpnr's own utilisation
        const QString pnr = readAll(m_p.logPath("pnr"));
        static const QRegularExpression util("Info:\\s+(\\w+):\\s+(\\d+)/\\s*(\\d+)\\s+(\\d+)%");
        auto it = util.globalMatch(pnr);
        bool header = false;
        while (it.hasNext()) {
            const auto u = it.next();
            if (u.captured(2).toInt() == 0) continue;
            if (!header) { row("placed (nextpnr)", 0, 0, true); header = true; m_area->item(m_area->rowCount() - 1, 1)->setText(""); }
            row("   " + u.captured(1), u.captured(2).toInt(), u.captured(3).toInt(), false);
        }
        m_area->resizeColumnsToContents();
    }
    // clocks: the last "Max frequency for clock" line per clock; failing clocks' critical-path cells come back
    QSet<QString> refreshTiming() {
        m_timing->setRowCount(0);
        const QString pnr = readAll(m_p.logPath("pnr"));
        static const QRegularExpression fmax("(Info|Warning): Max frequency for clock\\s+'([^']+)':\\s+([\\d.]+) MHz \\((PASS|FAIL) at ([\\d.]+) MHz\\)");
        QMap<QString, QStringList> last;
        auto it = fmax.globalMatch(pnr);
        while (it.hasNext()) {
            const auto m = it.next();
            if (m.captured(2).startsWith("$")) continue;
            last[m.captured(2)] = {m.captured(3), m.captured(5), m.captured(4)};
        }
        QSet<QString> failing;
        for (auto c = last.begin(); c != last.end(); ++c) {
            const int r = m_timing->rowCount();
            m_timing->insertRow(r);
            m_timing->setItem(r, 0, new QTableWidgetItem(c.key()));
            m_timing->setItem(r, 1, new QTableWidgetItem(c.value()[0]));
            m_timing->setItem(r, 2, new QTableWidgetItem(c.value()[1]));
            auto* st = new QTableWidgetItem(c.value()[2]);
            const bool fail = c.value()[2] == "FAIL";
            st->setForeground(fail ? QColor(0xc0, 0x20, 0x20) : QColor(0x20, 0x80, 0x20));
            QFont f = st->font();
            f.setBold(true);
            st->setFont(f);
            m_timing->setItem(r, 3, st);
            if (fail) failing.insert(c.key());
        }
        m_timing->resizeColumnsToContents();
        // the critical path of every clock (failing ones are what the plot marks; with
        // none failing, the worst clock's path is shown so the plot still says where it runs)
        QString target;
        double worst = 1e9;
        for (auto c = last.begin(); c != last.end(); ++c) {
            const double slackRatio = c.value()[0].toDouble() / std::max(1.0, c.value()[1].toDouble());
            if (slackRatio < worst) { worst = slackRatio; target = c.key(); }
        }
        m_worstClock = failing.isEmpty() ? target : *failing.begin();
        parsePaths(pnr);
        // OpenSTA on nextpnr's SDF: "clk_sys period_min = 9.79 fmax = 102.17" per clock,
        // targets from the create_clock lines the prep script wrote
        const QString sta = readAll(m_p.logPath("sta"));
        if (!sta.isEmpty()) {
            QMap<QString, double> period;
            static const QRegularExpression cc("create_clock -name (\\S+) -period ([\\d.]+)");
            auto ci = cc.globalMatch(readAll(m_p.vars["work"] + "/sta/sta.tcl"));
            while (ci.hasNext()) { const auto m = ci.next(); period[m.captured(1)] = m.captured(2).toDouble(); }
            static const QRegularExpression pm("^(\\S+) period_min = ([\\d.]+) fmax = ([\\d.]+)", QRegularExpression::MultilineOption);
            auto pi = pm.globalMatch(sta);
            while (pi.hasNext()) {
                const auto m = pi.next();
                const double tgt = period.value(m.captured(1)) > 0 ? 1000.0 / period.value(m.captured(1)) : 0;
                const bool fail = tgt > 0 && m.captured(3).toDouble() < tgt;
                const int r = m_timing->rowCount();
                m_timing->insertRow(r);
                m_timing->setItem(r, 0, new QTableWidgetItem(m.captured(1) + " (OpenSTA)"));
                m_timing->setItem(r, 1, new QTableWidgetItem(m.captured(3)));
                m_timing->setItem(r, 2, new QTableWidgetItem(tgt > 0 ? QString::number(tgt, 'f', 2) : "-"));
                auto* st = new QTableWidgetItem(fail ? "FAIL" : "PASS");
                st->setForeground(fail ? QColor(0xc0, 0x20, 0x20) : QColor(0x20, 0x80, 0x20));
                QFont f = st->font();
                f.setBold(true);
                st->setFont(f);
                m_timing->setItem(r, 3, st);
            }
            m_timing->resizeColumnsToContents();
            parseStaPaths(sta);
        }
        // The P&R passes that decide a deep memory's timing, from their log lines
        auto infoRow = [&](const QString& what, const QString& value, const QString& status, bool good) {
            const int r = m_timing->rowCount();
            m_timing->insertRow(r);
            m_timing->setItem(r, 0, new QTableWidgetItem(what));
            m_timing->setItem(r, 1, new QTableWidgetItem(value));
            m_timing->setItem(r, 2, new QTableWidgetItem(QString()));
            auto* st = new QTableWidgetItem(status);
            st->setForeground(good ? QColor(0x20, 0x80, 0x20) : QColor(0xc0, 0x20, 0x20));
            QFont f = st->font();
            f.setBold(true);
            st->setFont(f);
            m_timing->setItem(r, 3, st);
            return r;
        };
        static const QRegularExpression ct("clock-tree: ([^,\\n]+)");
        static const QRegularExpression bp("bram-place: (\\d+) block RAMs in (\\d+) read-mux groups");
        const auto ctm = ct.match(pnr);
        if (ctm.hasMatch()) {
            const bool modelled = !ctm.captured(1).startsWith("no ");  // "no clock delays measured for <die>"
            infoRow("clock tree model", modelled ? ctm.captured(1) : "not measured for this die",
                    modelled ? "ON" : "OFF", modelled);
        }
        const auto bpm = bp.match(pnr);
        if (bpm.hasMatch())
            infoRow("block RAM placement", bpm.captured(1) + " in " + bpm.captured(2) + " groups", "ON", true);
        // The block RAM figure of merit (the fom step, bram_fom.py): each block
        // RAM's worst estimated read path to the registers it feeds, from the
        // placement alone, against the project's budget ("bram_fom_budget":
        // "worst/p95" in ps, where the board showed the line)
        const QString fom = readAll(m_p.logPath("fom"));
        static const QRegularExpression fr("^(\\S+)\\s+(\\d+)\\s+(\\d+)\\s+(\\d+)\\s+(\\d+)\\s+(\\d+)",
                                           QRegularExpression::MultilineOption);
        const auto fm = fr.match(fom);
        if (fm.hasMatch()) {
            const QStringList budget = m_p.vars.value("bram_fom_budget").split('/');
            const bool judged = budget.size() == 2;
            const bool ok = judged && fm.captured(2).toDouble() <= budget[0].toDouble() &&
                            fm.captured(3).toDouble() <= budget[1].toDouble();
            const int r = infoRow("block RAM read paths, worst / p95 (ps)", fm.captured(2) + " / " + fm.captured(3),
                                  judged ? (ok ? "PASS" : "FAIL") : "-", ok || !judged);
            if (judged) m_timing->item(r, 2)->setText(budget[0] + " / " + budget[1]);
        }
        m_timing->resizeColumnsToContents();
        fillPathClocks();
        QSet<QString> hot;
        static const QRegularExpression rep("Critical path report for clock '([^']+)'");
        static const QRegularExpression cellRef("(?:Source|Sink)\\s+([^\\s]+)\\.[A-Za-z0-9_\\[\\]]+\\s*$");
        const QStringList lines = pnr.split('\n');
        QString cur;
        for (const QString& ln : lines) {
            const auto r = rep.match(ln);
            if (r.hasMatch()) { cur = r.captured(1); continue; }
            if (ln.startsWith("Info: Max frequency")) cur.clear();
            if (cur.isEmpty() || !(failing.contains(cur) || (failing.isEmpty() && cur == target))) continue;
            const auto c = cellRef.match(ln);
            if (c.hasMatch()) hot.insert(c.captured(1));
        }
        return hot;
    }
    // "Info:   clk-to-q  0.30  0.30 Source uart_send_divcnt_0.Q"
    // "Info:    routing  0.39  0.70 Net uart.send_divcnt[0] (45,199) -> (48,197)"
    // "Info:                          Sink lut_new_n5310_1168.A6"
    void parsePaths(const QString& log) {
        m_paths.clear();
        static const QRegularExpression rep("Critical path report for clock '([^']+)'");
        static const QRegularExpression row("^Info:\\s+(\\S+)\\s+([\\d.]+)\\s+([\\d.]+)\\s+(Source|Net)\\s+(\\S+)(?:\\s+\\((\\d+),(\\d+)\\)\\s+->\\s+\\((\\d+),(\\d+)\\))?");
        static const QRegularExpression sink("^Info:\\s+Sink\\s+(\\S+)");
        QString cur;
        QList<PathRow> rows;
        auto flush = [&] { if (!cur.isEmpty() && !rows.isEmpty()) m_paths[cur] = rows; rows.clear(); };
        for (const QString& ln : log.split('\n')) {
            const auto r = rep.match(ln);
            if (r.hasMatch()) { flush(); cur = r.captured(1); continue; }
            if (cur.isEmpty()) continue;
            const auto m = row.match(ln);
            if (m.hasMatch()) {
                PathRow pr{m.captured(1), m.captured(2), m.captured(3), m.captured(5), QString(), {}, {}, false};
                if (m.captured(4) == "Source") pr.cell = pr.name.section('.', 0, -2);
                if (!m.captured(6).isEmpty()) {
                    pr.from = QPointF(m.captured(6).toInt(), m.captured(7).toInt());
                    pr.to = QPointF(m.captured(8).toInt(), m.captured(9).toInt());
                    pr.hop = true;
                }
                rows << pr;
                continue;
            }
            const auto k = sink.match(ln);
            if (k.hasMatch()) {
                PathRow pr{"sink", "", "", k.captured(1), k.captured(1).section('.', 0, -2), {}, {}, false};
                if (!rows.isEmpty() && rows.last().hop) pr.from = rows.last().to;
                rows << pr;
                continue;
            }
            if (ln.startsWith("Info: Max frequency") || ln.trimmed() == "Info:") flush(), cur.clear();
        }
        flush();
    }
    void fillPathClocks() {
        const QString keep = m_pathClock->currentText();
        m_pathClock->blockSignals(true);
        m_pathClock->clear();
        for (auto it = m_paths.begin(); it != m_paths.end(); ++it) m_pathClock->addItem(it.key());
        m_pathClock->blockSignals(false);
        QString want = m_paths.contains(keep) ? keep : m_worstClock;
        if (!m_paths.contains(keep))  // OpenSTA sees every path through nextpnr's SDF: prefer it
            for (auto it = m_paths.begin(); it != m_paths.end(); ++it)
                if (it.key().endsWith("(OpenSTA)")) { want = it.key(); break; }
        if (!want.isEmpty()) m_pathClock->setCurrentText(want);
        showPath(m_pathClock->currentText());
    }
    // the first max path of each group in OpenSTA's full report, up to its data arrival:
    // "    103    0.303    1.065 ^ rstcnt_15/Q (SLICE_FFX)"
    void parseStaPaths(const QString& log) {
        static const QRegularExpression grp("^Path Group: (\\S+)");
        static const QRegularExpression row("^\\s*(\\d+)?\\s+(-?[\\d.]+)\\s+(-?[\\d.]+) ([\\^v]) (\\S+)/(\\S+) \\((\\S+)\\)");
        QString cur;
        bool max = false, inData = false;
        QList<PathRow> rows;
        for (const QString& ln : log.split('\n')) {
            const auto g = grp.match(ln);
            if (g.hasMatch()) { cur = g.captured(1) + " (OpenSTA)"; rows.clear(); inData = true; max = false; continue; }
            if (ln.startsWith("Path Type: max")) { max = true; continue; }
            if (!inData || !max || cur.isEmpty() || m_paths.contains(cur)) continue;
            if (ln.contains("data arrival time")) { m_paths[cur] = rows; inData = false; continue; }
            const auto m = row.match(ln);
            if (!m.hasMatch()) continue;
            const QString inst = m.captured(5), pin = m.captured(6), type = m.captured(7);
            QString kind = type.startsWith("BUFG") ? "clock" : rows.isEmpty() || rows.last().cell != inst ? "arrive" : "cell";
            if (!rows.isEmpty() && rows.last().cell == inst) rows.last().type = "arrive";
            rows << PathRow{kind, m.captured(2), m.captured(3), inst + "/" + pin + "  (" + type.section("__", 0, 0) + ")", inst, {}, {}, false};
        }
    }
    void showPath(const QString& clock) {
        m_path->setRowCount(0);
        QList<QPair<QPointF, QPointF>> hops;
        for (const PathRow& r : m_paths.value(clock)) {
            const int i = m_path->rowCount();
            m_path->insertRow(i);
            auto* t = new QTableWidgetItem(r.type);
            t->setData(Qt::UserRole, r.cell);
            t->setData(Qt::UserRole + 1, r.hop ? r.to : r.from);
            m_path->setItem(i, 0, t);
            m_path->setItem(i, 1, new QTableWidgetItem(r.curr));
            m_path->setItem(i, 2, new QTableWidgetItem(r.total));
            m_path->setItem(i, 3, new QTableWidgetItem(r.name));
            m_path->setItem(i, 4, new QTableWidgetItem(r.hop ? QString("(%1,%2) -> (%3,%4)").arg(r.from.x()).arg(r.from.y()).arg(r.to.x()).arg(r.to.y()) : QString()));
            if (r.type == "routing") for (int c = 0; c < 5; ++c) m_path->item(i, c)->setForeground(QColor(0x60, 0x60, 0x90));
            if (r.hop) hops << qMakePair(r.from, r.to);
        }
        if (hops.isEmpty()) {  // OpenSTA paths: join the placed cells in order
            QPointF last; bool have = false; QString lastCell;
            for (const PathRow& r : m_paths.value(clock)) {
                if (r.cell.isEmpty() || r.cell == lastCell) continue;
                lastCell = r.cell;
                QPointF g;
                if (!m_chip->gridPos(r.cell, g)) continue;
                if (have) hops << qMakePair(last, g);
                last = g; have = true;
            }
        }
        m_path->resizeColumnsToContents();
        m_chip->drawPath(hops);
        m_results->setTabText(m_results->indexOf(m_pathPanel), clock.isEmpty() ? "Critical path" : "Critical path (" + clock + ")");
    }
    void refreshProblems() {
        m_problems->clear();
        static const QRegularExpression loc("(%Error|%Warning-[A-Z]+|ERROR|CRITICAL WARNING|Warning-MAP)[^:]*:\\s*(?:([^:\\s]+\\.(?:sv|v|xdc)):(\\d+):)?(.*)");
        for (const Step& s : m_p.steps) {
            const QStringList lines = readAll(m_p.logPath(s.id)).split('\n');
            for (const QString& ln : lines) {
                if (!(ln.startsWith("%Error") || ln.startsWith("%Warning-MAP") || ln.startsWith("ERROR") || ln.startsWith("CRITICAL WARNING"))) continue;
                auto* it = new QListWidgetItem(QString("[%1] %2").arg(s.label, ln.left(220)));
                const auto m = loc.match(ln);
                if (m.hasMatch() && !m.captured(2).isEmpty()) {
                    it->setData(Qt::UserRole, m_p.abs(m.captured(2)));
                    it->setData(Qt::UserRole + 1, m.captured(3).toInt());
                }
                it->setForeground(ln.contains("Error") || ln.startsWith("ERROR") ? QColor(0xc0, 0x20, 0x20) : QColor(0xa0, 0x60, 0x00));
                m_problems->addItem(it);
            }
        }
        m_results->setTabText(m_results->indexOf(m_problems), QString("Problems (%1)").arg(m_problems->count()));
    }

    Project m_p;
    QTreeWidget* m_files;
    QTabWidget* m_editors;
    QTabWidget* m_results;
    QTableWidget* m_area;
    QTableWidget* m_timing;
    ChipView* m_chip;
    QLabel* m_legend;
    QWidget* m_chipPanel;
    QListWidget* m_problems;
    QComboBox* m_pathClock;
    QTableWidget* m_path;
    QWidget* m_pathPanel;
    struct PathRow { QString type, curr, total, name, cell; QPointF from, to; bool hop = false; };
    QMap<QString, QList<PathRow>> m_paths;  // clock -> its last critical-path report
    QString m_worstClock;
    QWidget* m_logPanel;
    QListWidget* m_logList;
    QStackedWidget* m_logStack;
    QMap<QString, QPlainTextEdit*> m_logs;  // step id -> its page
    QPlainTextEdit* m_curLog = nullptr;     // the running step's page
    QMap<QString, QLabel*> m_stepStatus;
    QMap<QString, QAction*> m_stepAction;
    QTabWidget* m_side = nullptr;
    QList<Step> m_queue;
    Step m_cur;
    QProcess* m_proc = nullptr;
    QThread* m_toolThread = nullptr;
    QList<Piece> m_pieces;
    QString m_cwd;  // where a step's `cd` has gone (runDirect)
    QFile m_logFile;
    qint64 m_t0 = 0;
    std::function<void(bool)> m_done;
};

int main(int argc, char** argv) {
    // tools built in (tools/): run before any GUI exists, so they are quick and work headless
    if (argc >= 3 && !strcmp(argv[1], "--tool")) {
        const char* tool = argv[2];
        char** targv = argv + 2;
        int targc = argc - 2;
        if (!strcmp(tool, "fasm2frames")) return fasm2frames_main(targc, targv);
        if (!strcmp(tool, "bit2uf2")) return bit2uf2_main(targc, targv);
        if (!strcmp(tool, "sta-prep")) return sta_prep_main(targc, targv);
        if (!strcmp(tool, "bram-fom")) return bram_fom_main(targc, targv);
        fprintf(stderr, "synthgui: no built-in tool '%s' (fasm2frames, bit2uf2, sta-prep, bram-fom)\n", tool);
        return 2;
    }
    QApplication app(argc, argv);
    QCoreApplication::setOrganizationDomain("kimmitt.uk");     // settings: uk.kimmitt.synthgui on macOS
    QCoreApplication::setApplicationName("synthgui");
    {   // the OpenXC7 logo (assets/): title bar, taskbar, and the Dock when not started from synthgui.app
        QIcon appIcon;
        for (int s : {16, 24, 32, 48, 64, 128, 256}) appIcon.addFile(QString(":/icon/synthgui-%1.png").arg(s), QSize(s, s));
        app.setWindowIcon(appIcon);
    }
    QCommandLineParser cl;
    cl.addHelpOption();
    cl.addOption({"project", "project file (JSON)", "file"});
    cl.addOption({"screenshot", "render a view to a PNG and exit", "png"});
    cl.addOption({"view", "view for --screenshot: chip, area, timing, log, problems, synthesis, pnr", "name", "chip"});
    cl.addOption({"print-command", "print a step's command, the options applied, and exit", "step"});
    cl.addOption({"set-option", "turn an option on with this value, or off with an empty one, and save it in the "
                                "project (repeatable; keys as in the project's \"options\")", "key=value"});
    cl.addOption({"log", "step whose log the log view shows (--screenshot)", "id", "pnr"});
    cl.addOption({"work", "use this work directory instead of the project's own", "dir"});
    cl.addOption({"run", "run these steps first (comma-separated ids, or all), then screenshot or exit", "steps"});
    QCommandLineOption selftestSettings("selftest-settings", "open the Settings dialog, set its UF2 checkbox on or off (keep: leave it), "
                                       "--screenshot it, accept it and print what is stored", "on|off|keep");
    selftestSettings.setFlags(QCommandLineOption::HiddenFromHelp);
    cl.addOption(selftestSettings);
    QCommandLineOption selftest("selftest-new", "fill and create a new project: name,out.json,work,xdc,src...", "fields");
    selftest.setFlags(QCommandLineOption::HiddenFromHelp);
    cl.addOption(selftest);
    cl.process(app);
    if (cl.isSet("work")) Project::workOverride = QDir(cl.value("work")).absoluteFilePath(".");
    if (cl.isSet("selftest-settings")) {  // drive the Settings dialog without a user
        SettingsDialog d;
        const QString v = cl.value("selftest-settings");
        if (v == "on" || v == "off") d.write->setChecked(v == "on");
        if (cl.isSet("screenshot")) { d.show(); app.processEvents(); d.grab().save(cl.value("screenshot")); }
        d.save();
        std::printf("uf2/writeOnRunAll=%d\n", writeNonVolatileOnRunAll() ? 1 : 0);
        return 0;
    }
    Project p;
    QString err;
    QString file = cl.value("project");
    if (cl.isSet("selftest-new")) {  // drive the new-project dialog without a user
        const QStringList a = cl.value("selftest-new").split(',');  // name,out.json,work,xdc,src...
        NewProjectDialog d;
        d.fill(a.value(0), a.mid(4), a.value(3), a.value(2), a.value(1));
        if (cl.isSet("screenshot")) { d.show(); app.processEvents(); d.grab().save(cl.value("screenshot")); }
        d.create();
        if (d.created.isEmpty()) return 1;
        file = d.created;
        if (cl.isSet("screenshot")) return 0;
    }
    if (file.isEmpty()) {
        if (cl.isSet("run") || cl.isSet("screenshot")) {
            QMessageBox::critical(nullptr, "synthgui", "--run and --screenshot need --project p.json");
            return 2;
        }
        NewProjectDialog d;
        if (d.exec() != QDialog::Accepted) return 0;
        file = d.created;
    }
    if (!p.load(file, err)) {
        QMessageBox::critical(nullptr, "synthgui", err);
        return 2;
    }
    if (cl.isSet("set-option")) {
        for (const QString& kv : cl.values("set-option")) {
            const QString k = kv.section('=', 0, 0), v = kv.section('=', 1);
            if (v.isEmpty()) p.options.remove(k);
            else p.options[k] = v;
        }
        p.applyOptions();
        if (!p.saveOptions(err)) { fprintf(stderr, "%s\n", qPrintable(err)); return 2; }
        if (!cl.isSet("print-command") && !cl.isSet("run") && !cl.isSet("screenshot")) return 0;
    }
    if (cl.isSet("print-command")) {
        for (const Step& s : p.steps)
            if (s.id == cl.value("print-command")) { printf("%s\n", qPrintable(p.expand(s.command))); return 0; }
        fprintf(stderr, "no step %s\n", qPrintable(cl.value("print-command")));
        return 2;
    }
    MainWindow w(p);
    auto shoot = [&] {
        w.view(cl.value("view"));
        if (cl.value("view") == "log") w.showLog(cl.value("log"));
        QTimer::singleShot(300, [&] {
            w.fitChip();
            QTimer::singleShot(200, [&] {
                if (cl.isSet("screenshot")) w.grab().save(cl.value("screenshot"));
                app.quit();
            });
        });
    };
    if (cl.isSet("run")) {
        w.show();
        int rc = 0;
        QTimer::singleShot(0, [&] { w.runThen(cl.value("run").split(','), [&](bool ok) { rc = ok ? 0 : 1; shoot(); }); });
        app.exec();
        return rc;
    }
    if (cl.isSet("screenshot")) {
        w.view(cl.value("view"));
        if (cl.value("view") == "log") w.showLog(cl.value("log"));
        w.show();
        QTimer::singleShot(300, [&] {
            w.fitChip();
            QTimer::singleShot(200, [&] {
                w.grab().save(cl.value("screenshot"));
                app.quit();
            });
        });
        return app.exec();
    }
    w.show();
    return app.exec();
}

void openProjectWindow(const QString& file) {
    Project p;
    QString err;
    if (!p.load(file, err)) {
        QMessageBox::critical(nullptr, "synthgui", err);
        return;
    }
    auto* w = new MainWindow(p);
    w->setAttribute(Qt::WA_DeleteOnClose);
    w->show();
}
