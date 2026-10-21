// inversion_bench.cc -- compare SMatrix<double,6,6,MatRepSym>::Invert (Bunch-Kaufman, what KinKal::FitData::invert uses)
// with InvertChol (Cholesky) on symmetric positive-definite 6x6 matrices: accuracy, agreement, failures, time per call.
// Inputs: synthetic SPD matrices over a condition-number range, plus optional real matrices from a text dump
// (one matrix per line: 21 lower-triangle values, row-major), e.g. KinKal covariances/weights.
// Build/run: inversion_bench.sh (ROOT headers only; no KinKal or Offline library).
#include "Math/SMatrix.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <fstream>
#include <random>
#include <sstream>
#include <string>
#include <vector>

using SYM = ROOT::Math::SMatrix<double, 6, 6, ROOT::Math::MatRepSym<double, 6>>;
using GEN = ROOT::Math::SMatrix<double, 6, 6>;
using VEC = ROOT::Math::SVector<double, 6>;

// random SPD matrix with eigenvalues log-spaced over [1, cond], then scaled per row/column like fit parameters
// (KinKal parameters span mm, rad, ns, 1/mm, so diagonal scales differ by many orders of magnitude)
static SYM randomSPD(std::mt19937_64& rng, double cond, const double* scale) {
  std::normal_distribution<double> g(0.0, 1.0);
  GEN q;
  for (int i = 0; i < 6; ++i)
    for (int j = 0; j < 6; ++j) q(i, j) = g(rng);
  // Gram-Schmidt -> orthogonal Q
  for (int j = 0; j < 6; ++j) {
    for (int k = 0; k < j; ++k) {
      double d = 0;
      for (int i = 0; i < 6; ++i) d += q(i, j) * q(i, k);
      for (int i = 0; i < 6; ++i) q(i, j) -= d * q(i, k);
    }
    double n = 0;
    for (int i = 0; i < 6; ++i) n += q(i, j) * q(i, j);
    n = std::sqrt(n);
    for (int i = 0; i < 6; ++i) q(i, j) /= n;
  }
  double ev[6];
  for (int k = 0; k < 6; ++k) ev[k] = std::pow(cond, k / 5.0);
  std::shuffle(ev, ev + 6, rng);
  SYM m;
  for (int i = 0; i < 6; ++i)
    for (int j = 0; j <= i; ++j) {
      double s = 0;
      for (int k = 0; k < 6; ++k) s += q(i, k) * ev[k] * q(j, k);
      m(i, j) = s * scale[i] * scale[j];
    }
  return m;
}

// max |A*Ainv - I| element, the backward-error measure (independent of which inverse is "right")
static double residual(SYM const& a, SYM const& ainv) {
  GEN p = GEN(a) * GEN(ainv);
  double r = 0;
  for (int i = 0; i < 6; ++i)
    for (int j = 0; j < 6; ++j) r = std::max(r, std::fabs(p(i, j) - (i == j ? 1.0 : 0.0)));
  return r;
}

// max relative difference between two inverses, element-wise, relative to sqrt(|diag_i diag_j|)
static double reldiff(SYM const& x, SYM const& y) {
  double r = 0;
  for (int i = 0; i < 6; ++i)
    for (int j = 0; j <= i; ++j) {
      double s = std::sqrt(std::fabs(x(i, i) * x(j, j)));
      if (s > 0) r = std::max(r, std::fabs(x(i, j) - y(i, j)) / s);
    }
  return r;
}

struct Stats {
  long n = 0, failBK = 0, failChol = 0, nonfinite = 0;
  std::vector<double> resBK, resChol, diff;
};

static FILE* gFailOut = nullptr;  // matrices Cholesky refuses, with their eigenvalues, for the fallback study

static void eigen(SYM const& m, double* ev) {
  // Jacobi eigenvalues of a symmetric 6x6 (diagnostic only)
  double a[6][6];
  for (int i = 0; i < 6; ++i)
    for (int j = 0; j < 6; ++j) a[i][j] = m(i, j);
  for (int sweep = 0; sweep < 100; ++sweep) {
    double off = 0;
    for (int p = 0; p < 6; ++p)
      for (int q = p + 1; q < 6; ++q) off += a[p][q] * a[p][q];
    if (off < 1e-300) break;
    for (int p = 0; p < 6; ++p)
      for (int q = p + 1; q < 6; ++q) {
        if (a[p][q] == 0) continue;
        double th = 0.5 * std::atan2(2 * a[p][q], a[q][q] - a[p][p]);
        double c = std::cos(th), s = std::sin(th);
        for (int k = 0; k < 6; ++k) {
          double akp = a[k][p], akq = a[k][q];
          a[k][p] = c * akp - s * akq;
          a[k][q] = s * akp + c * akq;
        }
        for (int k = 0; k < 6; ++k) {
          double apk = a[p][k], aqk = a[q][k];
          a[p][k] = c * apk - s * aqk;
          a[q][k] = s * apk + c * aqk;
        }
      }
  }
  for (int i = 0; i < 6; ++i) ev[i] = a[i][i];
  std::sort(ev, ev + 6);
}

static void compare(SYM const& m, Stats& st) {
  SYM a = m, b = m;
  bool okA = a.Invert(), okB = b.InvertChol();
  ++st.n;
  if (!okA) ++st.failBK;
  if (!okB) ++st.failChol;
  if (!okB && gFailOut) {
    double ev[6];
    eigen(m, ev);
    std::fprintf(gFailOut, "BKok=%d eig %.3e %.3e %.3e %.3e %.3e %.3e diag", okA, ev[0], ev[1], ev[2], ev[3], ev[4], ev[5]);
    for (int i = 0; i < 6; ++i) std::fprintf(gFailOut, " %.3e", m(i, i));
    std::fprintf(gFailOut, "\n");
  }
  if (!okA || !okB) return;
  if (!std::isfinite(a(0, 0)) || !std::isfinite(b(0, 0))) { ++st.nonfinite; return; }
  st.resBK.push_back(residual(m, a));
  st.resChol.push_back(residual(m, b));
  st.diff.push_back(reldiff(a, b));
}

static double pct(std::vector<double> v, double p) {
  if (v.empty()) return NAN;
  std::sort(v.begin(), v.end());
  return v[std::min(v.size() - 1, size_t(p * v.size()))];
}

static void report(const char* label, Stats const& st) {
  std::printf("%-30s n=%7ld failBK=%ld failChol=%ld nonfinite=%ld | residual |A*Ainv-I| p50/p99/max: BK %.1e/%.1e/%.1e"
              "  Chol %.1e/%.1e/%.1e | rel diff p50/p99/max %.1e/%.1e/%.1e\n",
              label, st.n, st.failBK, st.failChol, st.nonfinite, pct(st.resBK, .5), pct(st.resBK, .99),
              pct(st.resBK, 1.0), pct(st.resChol, .5), pct(st.resChol, .99), pct(st.resChol, 1.0), pct(st.diff, .5),
              pct(st.diff, .99), pct(st.diff, 1.0));
}

// time per call over a pool of matrices (copy + invert, as FitData::invert does on a copied FitData)
template <class F>
static double nsPerCall(std::vector<SYM> const& pool, int reps, F f) {
  double sink = 0;
  auto t0 = std::chrono::steady_clock::now();
  for (int r = 0; r < reps; ++r)
    for (auto const& m : pool) {
      SYM x = m;
      f(x);
      sink += x(0, 0);
    }
  auto t1 = std::chrono::steady_clock::now();
  if (sink == 12345.678) std::printf("#");
  return std::chrono::duration<double, std::nano>(t1 - t0).count() / (double(reps) * pool.size());
}

// callgrind mode: invert the same pool with one method only, so --toggle-collect counts Ir per call of that method
__attribute__((noinline)) static double runBK(std::vector<SYM> const& pool) {
  double s = 0;
  for (auto const& m : pool) { SYM x = m; x.Invert(); s += x(0, 0); }
  return s;
}
__attribute__((noinline)) static double runChol(std::vector<SYM> const& pool) {
  double s = 0;
  for (auto const& m : pool) { SYM x = m; x.InvertChol(); s += x(0, 0); }
  return s;
}

int main(int argc, char** argv) {
  std::mt19937_64 rng(20261020);
  if (argc > 1 && std::string(argv[1]) == "--irpercall") {
    const double sc[6] = {1.0, 1.0, 10.0, 10.0, 1e-3, 0.1};
    std::vector<SYM> pool;
    for (int k = 0; k < 10000; ++k) pool.push_back(randomSPD(rng, 1e6, sc));
    std::printf("%g %g\n", runBK(pool), runChol(pool));
    return 0;
  }
  // per-parameter scales spanning the LoopHelix parameter units (mm, mm, mm, mm, rad, ns), inverse for weights
  const double scale[6] = {1.0, 1.0, 10.0, 10.0, 1e-3, 0.1};
  const double conds[] = {1e2, 1e4, 1e6, 1e8, 1e10, 1e12, 1e14};
  std::vector<SYM> pool;
  std::printf("== synthetic SPD (eigenvalues log-spaced over [1,cond], LoopHelix-like diagonal scales)\n");
  for (double c : conds) {
    Stats st;
    for (int k = 0; k < 20000; ++k) {
      SYM m = randomSPD(rng, c, scale);
      compare(m, st);
      if (c <= 1e10 && pool.size() < 50000) pool.push_back(m);
    }
    char lab[64];
    std::snprintf(lab, sizeof lab, "cond %.0e", c);
    report(lab, st);
  }
  // not positive-definite: one negative or zero eigenvalue (what Cholesky must refuse and BK may still invert)
  {
    Stats st;
    for (int k = 0; k < 20000; ++k) {
      SYM m = randomSPD(rng, 1e4, scale);
      // subtract enough along a random direction to make one eigenvalue <= 0
      VEC v;
      std::normal_distribution<double> g(0, 1);
      for (int i = 0; i < 6; ++i) v[i] = g(rng) * scale[i];
      double s = 2.0 * 1e4 / ROOT::Math::Dot(v, v) * (1.0 + (k % 3));
      for (int i = 0; i < 6; ++i)
        for (int j = 0; j <= i; ++j) m(i, j) -= s * v[i] * v[j];
      compare(m, st);
    }
    report("indefinite (rank-1 downdate)", st);
  }
  // real matrices from a dump, if given
  for (int a = 1; a < argc; ++a) {
    std::ifstream in(argv[a]);
    std::string fo = std::string(argv[a]) + ".cholfail";
    gFailOut = std::fopen(fo.c_str(), "w");
    Stats st;
    std::string line;
    std::vector<SYM> real;
    while (std::getline(in, line)) {
      std::istringstream is(line);
      double v[21];
      int n = 0;
      while (n < 21 && is >> v[n]) ++n;
      if (n != 21) continue;
      SYM m;
      int k = 0;
      for (int i = 0; i < 6; ++i)
        for (int j = 0; j <= i; ++j) m(i, j) = v[k++];
      compare(m, st);
      real.push_back(m);
    }
    report(argv[a], st);
    if (gFailOut) { std::fclose(gFailOut); gFailOut = nullptr; }
    if (!real.empty()) {
      double bk = nsPerCall(real, 50, [](SYM& x) { x.Invert(); });
      double ch = nsPerCall(real, 50, [](SYM& x) { x.InvertChol(); });
      std::printf("  timing on these matrices: Invert (BK) %.1f ns/call, InvertChol %.1f ns/call, ratio %.2f\n", bk, ch,
                  ch / bk);
    }
  }
  std::printf("== timing on the synthetic pool (%zu matrices, cond <= 1e10)\n", pool.size());
  for (int t = 0; t < 2; ++t) {
    double bk = nsPerCall(pool, 40, [](SYM& x) { x.Invert(); });
    double ch = nsPerCall(pool, 40, [](SYM& x) { x.InvertChol(); });
    double chfb = nsPerCall(pool, 40, [](SYM& x) {
      SYM y = x;
      if (!x.InvertChol()) { x = y; x.Invert(); }
    });
    std::printf("trial %d: Invert (BK) %.1f ns/call, InvertChol %.1f ns/call (ratio %.2f), Chol with BK fallback %.1f"
                " ns/call (ratio %.2f)\n", t, bk, ch, ch / bk, chfb, chfb / bk);
  }
  return 0;
}
