// What the tools ported from Python need of Python's behaviour, so that their output is the same byte for byte:
//   V, parse, dump        json.load / json.dump (dicts keep insertion order, integers keep any size, ensure_ascii, float repr)
//   for_each_line, strip  text-mode lines (universal newlines), str.strip
//   parse_int             int(s) and int(s, 0)
//   repr, repr_list       %s of a string or a list
// Standard C++17 only, no state: the tools run in worker threads of the GUI and stand-alone on a board.
#pragma once
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <limits>
#include <locale>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>
#include <vector>

namespace pycompat {

using std::string;
using std::string_view;

inline string read_file(const string& p) {
    std::ifstream f(p, std::ios::binary);
    if (!f) throw std::runtime_error("cannot open " + p);
    string s;
    f.seekg(0, std::ios::end);
    auto n = f.tellg();
    if (n > 0) {
        s.resize((size_t)n);
        f.seekg(0);
        f.read(&s[0], n);
        if (!f) throw std::runtime_error("cannot read " + p);
    }
    return s;
}
inline void write_file(const string& p, const char* d, size_t n) {
    FILE* f = fopen(p.c_str(), "wb");
    if (!f) throw std::runtime_error("cannot write " + p);
    bool ok = fwrite(d, 1, n, f) == n;
    if (fclose(f) != 0) ok = false;
    if (!ok) throw std::runtime_error("write failed: " + p);
}
inline void write_file(const string& p, const string& s) { write_file(p, s.data(), s.size()); }

// ---------------------------------------------------------------- text
inline bool py_space(char c) { return c == ' ' || (c >= '\t' && c <= '\r') || (c >= 0x1c && c <= 0x1f); }
// str.strip, for ASCII whitespace (no FASM, frame or netlist text has the Unicode kind)
inline string_view strip(string_view s) {
    while (!s.empty() && py_space(s.front())) s.remove_prefix(1);
    while (!s.empty() && py_space(s.back())) s.remove_suffix(1);
    return s;
}
// the lines of a text-mode file, without their terminators: \n, \r\n and \r all end a line
template <class F> void for_each_line(string_view text, F&& fn) {
    size_t i = 0, n = text.size();
    while (i < n) {
        size_t j = i;
        while (j < n && text[j] != '\n' && text[j] != '\r') j++;
        fn(text.substr(i, j - i));
        if (j < n && text[j] == '\r' && j + 1 < n && text[j + 1] == '\n') j++;
        i = j + 1;
    }
}

// int(s) (base 10) and int(s, 0) (base 0).  Any size: low holds the magnitude's low 64 bits, big says it did not fit.
struct PyInt { bool ok = false, neg = false, big = false; uint64_t low = 0; };
inline PyInt parse_int(string_view text, int base) {
    PyInt r;
    string_view s = strip(text);
    if (!s.empty() && (s[0] == '+' || s[0] == '-')) { r.neg = s[0] == '-'; s.remove_prefix(1); }
    bool prefixed = false;
    if (base == 0) {
        base = 10;
        if (s.size() >= 2 && s[0] == '0') {
            char c = (char)(s[1] | 0x20);
            if (c == 'x') base = 16;
            else if (c == 'o') base = 8;
            else if (c == 'b') base = 2;
            if (base != 10) { s.remove_prefix(2); prefixed = true; }
        }
        // base 0 reads no leading zeros in a decimal number, except zero itself
        if (!prefixed && s.size() > 1 && s[0] == '0' && s.find_first_not_of("0_") != string_view::npos) return r;
    }
    if (s.empty()) return r;
    bool digit_before = prefixed;                               // "0x_1f" is fine, "_1" and "1__0" and "1_" are not
    bool last_us = false;
    for (char c : s) {
        if (c == '_') {
            if (!digit_before || last_us) return r;
            last_us = true;
            continue;
        }
        int d = c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : c >= 'A' && c <= 'F' ? c - 'A' + 10 : 99;
        if (d >= base) return r;
        uint64_t hi = (r.low >> 32) * (uint64_t)base, lo = (r.low & 0xffffffffu) * (uint64_t)base + (uint64_t)d;
        if ((hi + (lo >> 32)) >> 32) r.big = true;
        r.low = (hi << 32) + lo;
        digit_before = true;
        last_us = false;
    }
    if (last_us || !digit_before) return r;
    r.ok = true;
    return r;
}
// a value that must fit in an int64; throws where Python would raise or the value makes no sense here
inline int64_t to_int(string_view s, int base) {
    PyInt v = parse_int(s, base);
    if (!v.ok) throw std::runtime_error("invalid literal for int() with base " + std::to_string(base) + ": '" + string(s) + "'");
    if (v.big || v.low > (uint64_t)std::numeric_limits<int64_t>::max()) throw std::runtime_error("integer too large: " + string(s));
    return v.neg ? -(int64_t)v.low : (int64_t)v.low;
}

// repr() of a str, ASCII as printed; the rest passes through (Python would print it too when printable)
inline string repr(string_view s) {
    bool sq = s.find('\'') != string_view::npos, dq = s.find('"') != string_view::npos;
    char q = sq && !dq ? '"' : '\'';
    string r(1, q);
    for (char c : s) {
        if (c == q || c == '\\') { r += '\\'; r += c; }
        else if (c == '\n') r += "\\n";
        else if (c == '\t') r += "\\t";
        else if (c == '\r') r += "\\r";
        else if ((unsigned char)c < 0x20 || c == 0x7f) { char b[8]; snprintf(b, sizeof b, "\\x%02x", (unsigned char)c); r += b; }
        else r += c;
    }
    r += q;
    return r;
}
template <class C> string repr_list(const C& items) {
    string r = "[";
    bool first = true;
    for (const auto& x : items) { if (!first) r += ", "; first = false; r += repr(string_view(x)); }
    return r + "]";
}
template <class C> string int_list(const C& items) {
    string r = "[";
    bool first = true;
    for (const auto& x : items) { if (!first) r += ", "; first = false; r += std::to_string(x); }
    return r + "]";
}

// ---------------------------------------------------------------- JSON values
class V;
class Object;
using Array = std::vector<V>;

class V {
public:
    enum Type : uint8_t { Null, Bool, Int, BigInt, Float, Str, Arr, Obj };   // BigInt: an integer beyond int64, as text
    V() : t_(Null) { u_.i = 0; }
    V(int64_t i) : t_(Int) { u_.i = i; }
    V(int i) : t_(Int) { u_.i = i; }
    V(const char* s) : t_(Str) { u_.s = new string(s); }
    V(string s) : t_(Str) { u_.s = new string(std::move(s)); }
    inline V(const V& o);
    V(V&& o) noexcept : t_(o.t_), u_(o.u_) { o.t_ = Null; }
    V& operator=(V o) noexcept { std::swap(t_, o.t_); std::swap(u_, o.u_); return *this; }
    inline ~V();

    static inline V object();
    static V array() { V v; v.t_ = Arr; v.u_.a = new Array(); return v; }
    static V boolean(bool b) { V v; v.t_ = Bool; v.u_.i = b; return v; }
    static V real(double d) { V v; v.t_ = Float; v.u_.d = d; return v; }
    static V bigint(string text) { V v; v.t_ = BigInt; v.u_.s = new string(std::move(text)); return v; }

    Type type() const { return t_; }
    bool is_int() const { return t_ == Int; }
    bool is_str() const { return t_ == Str || t_ == BigInt; }
    bool is_string() const { return t_ == Str; }
    bool is_obj() const { return t_ == Obj; }
    bool is_arr() const { return t_ == Arr; }
    int64_t i() const { return u_.i; }
    double d() const { return u_.d; }
    const string& s() const { need(Str, "a string"); return *u_.s; }
    const string& raw() const { return *u_.s; }
    const Array& a() const { need(Arr, "a list"); return *u_.a; }
    Array& a() { need(Arr, "a list"); return *u_.a; }
    const Object& o() const { need(Obj, "an object"); return *u_.o; }
    Object& o() { need(Obj, "an object"); return *u_.o; }

    // m["key"], raising where Python raises KeyError
    inline const V& at(string_view k) const;
    inline V& at(string_view k);
    int64_t as_int() const { need(Int, "an integer"); return u_.i; }

private:
    void need(Type w, const char* what) const { if (t_ != w) throw std::runtime_error(string("JSON: expected ") + what); }
    Type t_;
    union { int64_t i; double d; string* s; Array* a; Object* o; } u_;
};

// a dict: insertion order; setting an existing key keeps its place; a hash index once it is large enough to matter
class Object {
public:
    using Item = std::pair<string, V>;
    const std::vector<Item>& items() const { return items_; }
    std::vector<Item>& items() { return items_; }
    size_t size() const { return items_.size(); }
    bool empty() const { return items_.empty(); }
    const V* find(string_view k) const {
        size_t i = pos(k);
        return i == npos ? nullptr : &items_[i].second;
    }
    V* find(string_view k) {
        size_t i = pos(k);
        return i == npos ? nullptr : &items_[i].second;
    }
    void set(string k, V v) {
        size_t i = pos(k);
        if (i != npos) { items_[i].second = std::move(v); return; }
        if (index_) (*index_)[k] = items_.size();
        items_.emplace_back(std::move(k), std::move(v));
    }
    bool erase(string_view k) {
        size_t i = pos(k);
        if (i == npos) return false;
        items_.erase(items_.begin() + (std::ptrdiff_t)i);
        index_.reset();
        return true;
    }

private:
    static constexpr size_t npos = (size_t)-1;
    size_t pos(string_view k) const {
        if (items_.size() <= 16) {
            for (size_t i = 0; i < items_.size(); i++) if (items_[i].first == k) return i;
            return npos;
        }
        if (!index_) {
            index_.reset(new std::unordered_map<string, size_t>());
            index_->reserve(items_.size() * 2);
            for (size_t i = 0; i < items_.size(); i++) (*index_)[items_[i].first] = i;
        }
        auto it = index_->find(string(k));
        return it == index_->end() ? npos : it->second;
    }
    std::vector<Item> items_;
    mutable std::unique_ptr<std::unordered_map<string, size_t>> index_;
};

inline V::V(const V& o) : t_(o.t_), u_(o.u_) {
    if (t_ == Str || t_ == BigInt) u_.s = new string(*o.u_.s);
    else if (t_ == Arr) u_.a = new Array(*o.u_.a);
    else if (t_ == Obj) {
        u_.o = new Object();
        u_.o->items() = o.u_.o->items();
    }
}
inline V::~V() {
    if (t_ == Str || t_ == BigInt) delete u_.s;
    else if (t_ == Arr) delete u_.a;
    else if (t_ == Obj) delete u_.o;
}
inline V V::object() { V v; v.t_ = Obj; v.u_.o = new Object(); return v; }
inline const V& V::at(string_view k) const {
    const V* p = o().find(k);
    if (!p) throw std::runtime_error("KeyError: " + repr(k));
    return *p;
}
inline V& V::at(string_view k) {
    V* p = o().find(k);
    if (!p) throw std::runtime_error("KeyError: " + repr(k));
    return *p;
}

// ---------------------------------------------------------------- json.load
class Parser {
public:
    const char* p; const char* e; string file;
    Parser(const string& text, string name) : p(text.data()), e(text.data() + text.size()), file(std::move(name)) {}
    [[noreturn]] void fail(const string& m) const { throw std::runtime_error(file + ": JSON: " + m); }
    void ws() { while (p < e && (*p == ' ' || *p == '\n' || *p == '\t' || *p == '\r')) p++; }
    V document() {
        V v = value();
        ws();
        if (p != e) fail("extra data");
        return v;
    }
    // a top-level object without holding it: fn(key, value) per member (a large tilegrid need not fit in memory)
    template <class F> void members(F&& fn) {
        ws();
        if (p >= e || *p != '{') fail("expected an object");
        p++; ws();
        if (p < e && *p == '}') { p++; }
        else for (;;) {
            ws();
            string k = str();
            ws();
            if (p >= e || *p != ':') fail("expected ':'");
            p++;
            fn(k, value());
            ws();
            if (p < e && *p == ',') { p++; continue; }
            if (p < e && *p == '}') { p++; break; }
            fail("expected ',' or '}'");
        }
        ws();
        if (p != e) fail("extra data");
    }
    string str() {
        if (p >= e || *p != '"') fail("expected a string");
        p++;
        string r;
        for (;;) {
            const char* q = p;
            while (q < e && *q != '"' && *q != '\\' && (unsigned char)*q >= 0x20) q++;
            r.append(p, (size_t)(q - p));
            p = q;
            if (p >= e) fail("unterminated string");
            if (*p == '"') { p++; return r; }
            if (*p != '\\') fail("invalid control character in a string");
            p++;
            if (p >= e) fail("bad escape");
            char c = *p++;
            switch (c) {
                case '"': case '\\': case '/': r += c; break;
                case 'n': r += '\n'; break;
                case 't': r += '\t'; break;
                case 'r': r += '\r'; break;
                case 'b': r += '\b'; break;
                case 'f': r += '\f'; break;
                case 'u': {
                    unsigned u = hex4();
                    // a surrogate pair is one character; a lone surrogate stays itself (3 bytes here, \uXXXX again on output)
                    if (u >= 0xD800 && u < 0xDC00 && e - p >= 6 && p[0] == '\\' && p[1] == 'u') {
                        const char* save = p;
                        p += 2;
                        unsigned u2 = hex4();
                        if (u2 >= 0xDC00 && u2 < 0xE000) u = 0x10000 + ((u - 0xD800) << 10) + (u2 - 0xDC00);
                        else p = save;
                    }
                    append_utf8(r, u);
                    break;
                }
                default: fail("invalid \\escape");
            }
        }
    }
    V value() {
        ws();
        if (p >= e) fail("unexpected end");
        char c = *p;
        if (c == '{') {
            V v = V::object();
            Object& o = v.o();
            p++; ws();
            if (p < e && *p == '}') { p++; return v; }
            for (;;) {
                ws();
                string k = str();
                ws();
                if (p >= e || *p != ':') fail("expected ':'");
                p++;
                o.set(std::move(k), value());                   // a repeated key: first place, last value, as a dict
                ws();
                if (p < e && *p == ',') { p++; continue; }
                if (p < e && *p == '}') { p++; return v; }
                fail("expected ',' or '}'");
            }
        }
        if (c == '[') {
            V v = V::array();
            Array& a = v.a();
            p++; ws();
            if (p < e && *p == ']') { p++; return v; }
            for (;;) {
                a.push_back(value());
                ws();
                if (p < e && *p == ',') { p++; continue; }
                if (p < e && *p == ']') { p++; return v; }
                fail("expected ',' or ']'");
            }
        }
        if (c == '"') return V(str());
        if (lit("true")) return V::boolean(true);
        if (lit("false")) return V::boolean(false);
        if (lit("null")) return V();
        if (lit("NaN")) return V::real(std::numeric_limits<double>::quiet_NaN());
        if (lit("Infinity")) return V::real(std::numeric_limits<double>::infinity());
        if (lit("-Infinity")) return V::real(-std::numeric_limits<double>::infinity());
        return number();
    }

private:
    bool lit(const char* w) {
        size_t n = strlen(w);
        if ((size_t)(e - p) >= n && !memcmp(p, w, n)) { p += n; return true; }
        return false;
    }
    unsigned hex4() {
        if (e - p < 4) fail("bad \\u");
        unsigned u = 0;
        for (int i = 0; i < 4; i++) {
            char c = *p++;
            int d = c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1;
            if (d < 0) fail("bad \\u");
            u = u * 16 + (unsigned)d;
        }
        return u;
    }
    static void append_utf8(string& r, unsigned c) {
        if (c < 0x80) r += (char)c;
        else if (c < 0x800) { r += (char)(0xC0 | c >> 6); r += (char)(0x80 | (c & 63)); }
        else if (c < 0x10000) { r += (char)(0xE0 | c >> 12); r += (char)(0x80 | ((c >> 6) & 63)); r += (char)(0x80 | (c & 63)); }
        else { r += (char)(0xF0 | c >> 18); r += (char)(0x80 | ((c >> 12) & 63)); r += (char)(0x80 | ((c >> 6) & 63)); r += (char)(0x80 | (c & 63)); }
    }
    static bool dig(char c) { return c >= '0' && c <= '9'; }
    V number() {
        const char* s = p;
        const char* q = p;
        if (q < e && *q == '-') q++;
        if (q >= e || !dig(*q)) fail("expected a value");
        if (*q == '0') q++;
        else while (q < e && dig(*q)) q++;
        const char* int_end = q;
        bool fl = false;
        if (q + 1 < e && *q == '.' && dig(q[1])) { fl = true; q++; while (q < e && dig(*q)) q++; }
        if (q < e && (*q == 'e' || *q == 'E')) {
            const char* x = q + 1;
            if (x < e && (*x == '+' || *x == '-')) x++;
            if (x < e && dig(*x)) { fl = true; while (x < e && dig(*x)) x++; q = x; }
        }
        p = q;
        if (fl) return V::real(to_double(string(s, (size_t)(q - s))));
        size_t len = (size_t)(int_end - s);
        if (len <= 18) {
            int64_t v = 0;
            const char* d = *s == '-' ? s + 1 : s;
            for (; d < int_end; d++) v = v * 10 + (*d - '0');
            return V(*s == '-' ? -v : v);
        }
        return V::bigint(string(s, len));
    }
    static double to_double(const string& text) {
        std::istringstream is(text);
        is.imbue(std::locale::classic());
        double d = 0;
        is >> d;
        if (is.fail()) {                                        // out of range: float() gives inf or 0
            size_t x = text.find_first_of("eE");
            bool neg = text[0] == '-', down = x != string::npos && x + 1 < text.size() && text[x + 1] == '-';
            d = down ? 0.0 : std::numeric_limits<double>::infinity();
            if (neg) d = -d;
        }
        return d;
    }
};

inline V parse(const string& text, const string& name) {
    Parser jp(text, name);
    return jp.document();
}
inline V load(const string& path) { return parse(read_file(path), path); }

// ---------------------------------------------------------------- json.dump
// repr(float)
inline string float_repr(double d) {
    if (d != d) return "NaN";
    if (d == std::numeric_limits<double>::infinity()) return "Infinity";
    if (d == -std::numeric_limits<double>::infinity()) return "-Infinity";
    // the fewest significant digits that read back as the same double
    string sci;
    for (int prec = 0; prec <= 16; prec++) {
        std::ostringstream os;
        os.imbue(std::locale::classic());
        os.precision(prec);
        os << std::scientific << d;
        sci = os.str();
        std::istringstream is(sci);
        is.imbue(std::locale::classic());
        double back = 0;
        is >> back;
        if (!is.fail() && back == d) break;                     // past the range is a failure, whatever it stored
    }
    bool neg = sci[0] == '-';
    size_t x = sci.find('e');
    string digits;
    for (size_t i = neg ? 1 : 0; i < x; i++) if (sci[i] != '.') digits += sci[i];
    int exp = atoi(sci.c_str() + x + 1);
    string r = neg ? "-" : "";
    if (exp >= -4 && exp < 16) {
        if (exp < 0) { r += "0."; r.append((size_t)(-exp - 1), '0'); r += digits; }
        else if ((size_t)exp + 1 >= digits.size()) { r += digits; r.append((size_t)exp + 1 - digits.size(), '0'); r += ".0"; }
        else { r += digits.substr(0, (size_t)exp + 1); r += '.'; r += digits.substr((size_t)exp + 1); }
    } else {
        r += digits[0];
        if (digits.size() > 1) { r += '.'; r += digits.substr(1); }
        r += 'e';
        r += exp < 0 ? '-' : '+';
        int a = exp < 0 ? -exp : exp;
        if (a < 10) r += '0';
        r += std::to_string(a);
    }
    return r;
}

// a JSON string with ensure_ascii=True
inline void dump_str(const string& s, string& out) {
    out += '"';
    size_t i = 0, n = s.size();
    char b[16];
    while (i < n) {
        unsigned char c = (unsigned char)s[i];
        if (c >= 0x20 && c < 0x7f && c != '"' && c != '\\') {
            size_t j = i + 1;
            while (j < n) { unsigned char x = (unsigned char)s[j]; if (x < 0x20 || x >= 0x7f || x == '"' || x == '\\') break; j++; }
            out.append(s, i, j - i);
            i = j;
            continue;
        }
        i++;
        switch (c) {
            case '"': out += "\\\""; continue;
            case '\\': out += "\\\\"; continue;
            case '\n': out += "\\n"; continue;
            case '\r': out += "\\r"; continue;
            case '\t': out += "\\t"; continue;
            case '\f': out += "\\f"; continue;
            case '\b': out += "\\b"; continue;
            default: break;
        }
        unsigned cp = c;
        int more = 0;
        if (c >= 0xF0 && c < 0xF5) { cp = c & 7; more = 3; }
        else if (c >= 0xE0 && c < 0xF0) { cp = c & 15; more = 2; }
        else if (c >= 0xC2 && c < 0xE0) { cp = c & 31; more = 1; }
        else if (c >= 0x80) throw std::runtime_error("JSON: a string is not UTF-8");
        for (int k = 0; k < more; k++, i++) {
            if (i >= n || ((unsigned char)s[i] & 0xC0) != 0x80) throw std::runtime_error("JSON: a string is not UTF-8");
            cp = (cp << 6) | ((unsigned char)s[i] & 63);
        }
        if (cp >= 0x10000) {
            cp -= 0x10000;
            snprintf(b, sizeof b, "\\u%04x\\u%04x", 0xD800 | (cp >> 10), 0xDC00 | (cp & 0x3FF));
        } else snprintf(b, sizeof b, "\\u%04x", cp);
        out += b;
    }
    out += '"';
}

// json.dump(v, f, indent=indent); indent < 0 is indent=None
inline void dump(const V& v, string& out, int indent, int level = 0) {
    auto newline = [&](int lv) { out += '\n'; out.append((size_t)(indent * lv), ' '); };
    switch (v.type()) {
        case V::Null: out += "null"; break;
        case V::Bool: out += v.i() ? "true" : "false"; break;
        case V::Int: {
            char b[32];
            snprintf(b, sizeof b, "%lld", (long long)v.i());
            out += b;
            break;
        }
        case V::BigInt: out += v.raw(); break;
        case V::Float: out += float_repr(v.d()); break;
        case V::Str: dump_str(v.s(), out); break;
        case V::Arr: {
            const Array& a = v.a();
            if (a.empty()) { out += "[]"; break; }
            out += '[';
            bool first = true;
            for (const V& x : a) {
                if (!first) out += indent < 0 ? ", " : ",";
                first = false;
                if (indent >= 0) newline(level + 1);
                dump(x, out, indent, level + 1);
            }
            if (indent >= 0) newline(level);
            out += ']';
            break;
        }
        case V::Obj: {
            const Object& o = v.o();
            if (o.empty()) { out += "{}"; break; }
            out += '{';
            bool first = true;
            for (const auto& kv : o.items()) {
                if (!first) out += indent < 0 ? ", " : ",";
                first = false;
                if (indent >= 0) newline(level + 1);
                dump_str(kv.first, out);
                out += ": ";
                dump(kv.second, out, indent, level + 1);
            }
            if (indent >= 0) newline(level);
            out += '}';
            break;
        }
    }
}
inline void dump_file(const V& v, const string& path, int indent) {
    string out;
    dump(v, out, indent);
    write_file(path, out);
}

// ---------------------------------------------------------------- argparse, as much of it as the tools use
struct Args {
    std::vector<string> pos;
    std::unordered_map<string, string> opt;
    bool help = false;
    bool has(const string& k) const { return opt.count(k) != 0; }
    string get(const string& k, const string& dflt = string()) const {
        auto it = opt.find(k);
        return it == opt.end() ? dflt : it->second;
    }
};
// value_opts: the "--name" options, all of which take a value.  Throws on anything else.
inline Args parse_args(int argc, char** argv, const std::vector<string>& value_opts) {
    Args a;
    for (int i = 1; i < argc; i++) {
        string w = argv[i];
        if (w == "-h" || w == "--help") { a.help = true; continue; }
        if (w.size() > 2 && w[0] == '-' && w[1] == '-') {
            string name = w, val;
            size_t eq = w.find('=');
            bool has_val = eq != string::npos;
            if (has_val) { name = w.substr(0, eq); val = w.substr(eq + 1); }
            if (std::find(value_opts.begin(), value_opts.end(), name) == value_opts.end()) throw std::runtime_error("unrecognized argument: " + w);
            if (!has_val) {
                if (i + 1 >= argc) throw std::runtime_error("argument " + name + ": expected one argument");
                val = argv[++i];
            }
            a.opt[name] = val;
            continue;
        }
        a.pos.push_back(w);
    }
    return a;
}

}  // namespace pycompat
