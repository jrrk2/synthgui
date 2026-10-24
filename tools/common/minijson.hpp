// A small JSON reader shared by the tools (objects keep their order, which the Python they replace relied on).
#pragma once
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace minijson {

inline std::string read_file(const std::string& p) {
    std::ifstream f(p, std::ios::binary);
    if (!f) throw std::runtime_error("cannot open " + p);
    std::stringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

struct JV {
    enum T { Null, Bool, Num, Str, Arr, Obj } t = Null;
    double n = 0;
    std::string s;
    std::vector<JV> a;
    std::vector<std::pair<std::string, JV>> o;
    const JV* get(const std::string& k) const {
        for (auto& kv : o) if (kv.first == k) return &kv.second;
        return nullptr;
    }
};
struct JP {
    const char* p; const char* e; std::string file;
    [[noreturn]] void fail(const char* m) { throw std::runtime_error(file + ": JSON " + m); }
    void ws() { while (p < e && (*p == ' ' || *p == '\n' || *p == '\t' || *p == '\r')) p++; }
    std::string str() {
        if (p >= e || *p != '"') fail("expected a std::string");
        p++;
        std::string r;
        while (p < e && *p != '"') {
            if (*p == '\\') {
                p++;
                if (p >= e) fail("bad escape");
                switch (*p) {
                    case 'n': r += '\n'; break;
                    case 't': r += '\t'; break;
                    case 'r': r += '\r'; break;
                    case 'b': r += '\b'; break;
                    case 'f': r += '\f'; break;
                    case 'u': {
                        if (e - p < 5) fail("bad \\u");
                        unsigned c = (unsigned)strtoul(std::string(p + 1, 4).c_str(), nullptr, 16);
                        p += 4;
                        if (c < 0x80) r += (char)c;
                        else if (c < 0x800) { r += (char)(0xC0 | c >> 6); r += (char)(0x80 | (c & 63)); }
                        else { r += (char)(0xE0 | c >> 12); r += (char)(0x80 | ((c >> 6) & 63)); r += (char)(0x80 | (c & 63)); }
                        break;
                    }
                    default: r += *p;
                }
                p++;
            } else r += *p++;
        }
        if (p >= e) fail("unterminated std::string");
        p++;
        return r;
    }
    JV value() {
        ws();
        if (p >= e) fail("unexpected end");
        JV v;
        if (*p == '{') {
            v.t = JV::Obj; p++; ws();
            if (p < e && *p == '}') { p++; return v; }
            for (;;) {
                ws(); std::string k = str(); ws();
                if (p >= e || *p != ':') fail("expected ':'");
                p++;
                v.o.emplace_back(std::move(k), value());
                ws();
                if (p < e && *p == ',') { p++; continue; }
                if (p < e && *p == '}') { p++; return v; }
                fail("expected ',' or '}'");
            }
        }
        if (*p == '[') {
            v.t = JV::Arr; p++; ws();
            if (p < e && *p == ']') { p++; return v; }
            for (;;) {
                v.a.push_back(value()); ws();
                if (p < e && *p == ',') { p++; continue; }
                if (p < e && *p == ']') { p++; return v; }
                fail("expected ',' or ']'");
            }
        }
        if (*p == '"') { v.t = JV::Str; v.s = str(); return v; }
        if (!strncmp(p, "true", 4)) { p += 4; v.t = JV::Bool; v.n = 1; return v; }
        if (!strncmp(p, "false", 5)) { p += 5; v.t = JV::Bool; return v; }
        if (!strncmp(p, "null", 4)) { p += 4; return v; }
        char* end;
        v.n = strtod(p, &end);
        if (end == p) fail("unexpected character");
        p = end; v.t = JV::Num;
        return v;
    }
};
inline JV json_file(const std::string& path) {
    std::string text = read_file(path);
    JP jp{text.data(), text.data() + text.size(), path};
    JV v = jp.value();
    return v;
}


}  // namespace minijson
