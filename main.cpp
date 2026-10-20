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
#include <QMainWindow>
#include <QMap>
#include <QMessageBox>
#include <QPlainTextEdit>
#include <QProcess>
#include <QRegularExpression>
#include <QSet>
#include <QShortcut>
#include <QSplitter>
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

// ---------------------------------------------------------------- project

// A project file: what to build and how.  Command templates use {name}
// placeholders for any of the string fields and for derived paths
// ({work}, {json}, {edif}, {fasm}, {placement}, {bit}, {sources}, {incdirs},
// {defines}, {blackboxes}).
struct Step {
    QString id, label, command;
};
struct Project {
    QString path, dir, name, top, work, device, part, xdc;
    QStringList sources, incdirs, defines, blackboxes;
    QMap<QString, QString> vars;  // every string field, for templates
    QList<Step> steps;
    QMap<QString, int> capacity;  // device resources for utilisation

    QString abs(const QString& p) const { return QDir::isAbsolutePath(p) ? p : QDir(dir).filePath(p); }
    static QString expandHome(QString s) {
        if (s.startsWith("~/")) s = QDir::homePath() + s.mid(1);
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
            steps << Step{s.value("id").toString(), s.value("label").toString(), s.value("command").toString()};
        }
        const QJsonObject cap = o.value("capacity").toObject();
        for (auto it = cap.begin(); it != cap.end(); ++it) capacity[it.key()] = it.value().toInt();
        vars["work"] = work;
        vars["json"] = work + "/" + top + ".json";
        vars["edif"] = work + "/" + top + ".edf";
        vars["fasm"] = work + "/" + top + ".fasm";
        vars["placement"] = work + "/" + top + "_placement.json";
        vars["bit"] = work + "/" + top + ".bit";
        vars["xdc"] = xdc;
        vars["sources"] = sources.join(' ');
        QStringList inc, def, bb;
        for (const QString& i : incdirs) inc << "-I" + i;
        for (const QString& d : defines) def << "+define+" + d;
        for (const QString& b : blackboxes) bb << "--struct-only-blackbox " + b;
        vars["incdirs"] = inc.join(' ');
        vars["defines"] = def.join(' ');
        vars["blackboxes"] = bb.join(' ');
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
        QFile f(placementFile);
        if (!f.open(QIODevice::ReadOnly)) { summary = "no placement yet (" + placementFile + ")"; return 0; }
        const QJsonObject cells = QJsonDocument::fromJson(f.readAll()).object();
        static const QRegularExpression xy("^X(\\d+)Y(\\d+)/");
        QMap<QString, int> counts;
        int maxX = 0, maxY = 0, n = 0;
        struct P { int x, y; QString kind; bool hot; };
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
            pts << P{x, y, kind, hot.contains(it.key())};
            counts[kind]++;
            ++n;
        }
        const qreal s = 3.0;
        m_scene.addRect(-2, -2, (maxX + 2) * s, (maxY + 2) * s, QPen(QColor(0x50, 0x55, 0x60)), Qt::NoBrush);
        for (const P& p : pts) {
            if (p.hot) continue;
            const QColor col = colour(p.kind);
            if (p.kind == "BRAM" || p.kind == "DSP")  // a RAMB36 / DSP48 pair spans five tile rows
                m_scene.addRect(p.x * s - s, p.y * s, s * 2.6, s * 4.6, QPen(col.darker(140)), col);
            else
                m_scene.addRect(p.x * s, p.y * s, s * 0.9, s * 0.9, Qt::NoPen, col);
        }
        int nhot = 0;
        for (const P& p : pts) {  // failing-path cells on top, large
            if (!p.hot) continue;
            m_scene.addEllipse(p.x * s - 3, p.y * s - 3, 9, 9, QPen(QColor(255, 255, 255), 1), QColor(0xff, 0x30, 0x30));
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
};

// ---------------------------------------------------------------- main window

class MainWindow final : public QMainWindow {
public:
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
        connect(m_editors, &QTabWidget::tabCloseRequested, this, [this](int i) { m_editors->removeTab(i); });
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
        m_problems = new QListWidget;
        connect(m_problems, &QListWidget::itemDoubleClicked, this, [this](QListWidgetItem* it) {
            const QString f = it->data(Qt::UserRole).toString();
            if (!f.isEmpty()) openFile(f, it->data(Qt::UserRole + 1).toInt());
        });
        m_log = new QPlainTextEdit;
        m_log->setReadOnly(true);
        m_log->setMaximumBlockCount(20000);
        QFont mono("Monospace");
        mono.setStyleHint(QFont::TypeWriter);
        m_log->setFont(mono);
        m_results->addTab(m_log, "Log");
        m_results->addTab(m_area, "Area");
        m_results->addTab(m_timing, "Timing");
        m_results->addTab(chipPanel, "Chip");
        m_chipPanel = chipPanel;
        m_results->addTab(m_problems, "Problems");

        auto* right = new QSplitter(Qt::Vertical);
        right->addWidget(m_editors);
        right->addWidget(m_results);
        right->setSizes({450, 500});
        auto* split = new QSplitter;
        split->addWidget(m_files);
        split->addWidget(right);
        split->setSizes({260, 1240});
        setCentralWidget(split);

        // pipeline
        auto* tb = addToolBar("Flow");
        for (const Step& s : m_p.steps) {
            QAction* a = tb->addAction(s.label, this, [this, s] { runSteps({s}); });
            a->setToolTip(m_p.expand(s.command));
            m_stepStatus[s.id] = new QLabel(" " + s.label + ": - ");
            statusBar()->addPermanentWidget(m_stepStatus[s.id]);
        }
        tb->addSeparator();
        tb->addAction("Run all", this, [this] { runSteps(m_p.steps); });
        tb->addAction("Stop", this, [this] { stop(); });
        tb->addAction("Reload results", this, [this] { refreshAll(); });

        if (!m_p.sources.isEmpty()) openFile(m_p.sources.last(), 0);
        refreshAll();
    }

    // render one view for --screenshot
    QWidget* view(const QString& name) {
        if (name == "area") { m_results->setCurrentWidget(m_area); return this; }
        if (name == "timing") { m_results->setCurrentWidget(m_timing); return this; }
        if (name == "log") { m_results->setCurrentWidget(m_log); return this; }
        if (name == "problems") { m_results->setCurrentWidget(m_problems); return this; }
        m_results->setCurrentWidget(m_chipPanel);
        return this;
    }
    void fitChip() { m_chip->fit(); }
    // batch: run these steps (ids, or "all"), then call done(ok)
    void runThen(const QStringList& ids, std::function<void(bool)> done) {
        QList<Step> steps;
        for (const Step& s : m_p.steps) if (ids.contains("all") || ids.contains(s.id)) steps << s;
        m_done = std::move(done);
        runSteps(steps);
    }
    void showLog(const QString& stepId) {
        QFile f(m_p.logPath(stepId));
        if (f.open(QIODevice::ReadOnly)) m_log->setPlainText(QString::fromLocal8Bit(f.readAll()).right(60000));
    }

private:
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
        auto* ed = qobject_cast<QPlainTextEdit*>(m_editors->currentWidget());
        if (!ed) return;
        QFile f(ed->property("file").toString());
        if (f.open(QIODevice::WriteOnly)) {
            f.write(ed->toPlainText().toUtf8());
            statusBar()->showMessage("saved " + f.fileName(), 3000);
        }
    }

    // ---- running the flow
    void runSteps(QList<Step> steps) {
        if (m_proc) return;
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
        m_log->clear();
        m_results->setCurrentWidget(m_log);
        m_log->appendPlainText("$ " + cmd + "\n");
        m_logFile.setFileName(m_p.logPath(s.id));
        m_logFile.open(QIODevice::WriteOnly | QIODevice::Truncate);
        m_stepStatus[s.id]->setText(" " + s.label + ": running ");
        m_stepStatus[s.id]->setStyleSheet("color: #b07000");
        m_t0 = QDateTime::currentMSecsSinceEpoch();
        m_proc = new QProcess(this);
        m_proc->setProcessChannelMode(QProcess::MergedChannels);
        m_proc->setWorkingDirectory(m_p.work);
        connect(m_proc, &QProcess::readyRead, this, [this] {
            const QByteArray b = m_proc->readAll();
            m_logFile.write(b);
            m_log->moveCursor(QTextCursor::End);
            m_log->insertPlainText(QString::fromLocal8Bit(b));
            m_log->moveCursor(QTextCursor::End);
        });
        connect(m_proc, qOverload<int, QProcess::ExitStatus>(&QProcess::finished), this, [this](int code, QProcess::ExitStatus) {
            m_logFile.close();
            const double secs = (QDateTime::currentMSecsSinceEpoch() - m_t0) / 1000.0;
            QLabel* l = m_stepStatus[m_cur.id];
            l->setText(QString(" %1: %2 (%3 s) ").arg(m_cur.label, code ? "FAILED" : "ok").arg(secs, 0, 'f', 0));
            l->setStyleSheet(code ? "color: #c02020" : "color: #208020");
            m_proc->deleteLater();
            m_proc = nullptr;
            refreshAll();
            if (code) {
                m_queue.clear();
                m_results->setCurrentWidget(m_problems);
                if (m_done) { auto d = m_done; m_done = nullptr; d(false); }
                return;
            }
            next();
        });
        m_proc->start("/bin/bash", {"-c", cmd});
    }
    void stop() {
        m_queue.clear();
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
    QPlainTextEdit* m_log;
    QMap<QString, QLabel*> m_stepStatus;
    QList<Step> m_queue;
    Step m_cur;
    QProcess* m_proc = nullptr;
    QFile m_logFile;
    qint64 m_t0 = 0;
    std::function<void(bool)> m_done;
};

int main(int argc, char** argv) {
    QApplication app(argc, argv);
    QCommandLineParser cl;
    cl.addHelpOption();
    cl.addOption({"project", "project file (JSON)", "file"});
    cl.addOption({"screenshot", "render a view to a PNG and exit", "png"});
    cl.addOption({"view", "view for --screenshot: chip, area, timing, log, problems", "name", "chip"});
    cl.addOption({"log", "step whose log the log view shows (--screenshot)", "id", "pnr"});
    cl.addOption({"run", "run these steps first (comma-separated ids, or all), then screenshot or exit", "steps"});
    cl.process(app);
    Project p;
    QString err;
    if (!cl.isSet("project") || !p.load(cl.value("project"), err)) {
        QMessageBox::critical(nullptr, "synthgui", cl.isSet("project") ? err : "usage: synthgui --project p.json");
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
