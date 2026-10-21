// nearestindex_equiv.cc -- check PiecewiseTrajectory::nearestIndex (binary search) against the linear scan of KinKal v3.8.0
// on random contiguous piece sets, boundary times, out-of-range times, NaN and equal-end pieces; then time both.
// Build/run: nearestindex_equiv.sh <area> (compiles against <area>/KinKal headers only; no KinKal library needed).
#include "KinKal/Trajectory/PiecewiseTrajectory.hh"
#include <chrono>
#include <cmath>
#include <cstdio>
#include <random>
#include <vector>

using KinKal::TimeRange;

// minimal piece: PiecewiseTrajectory only needs range() for nearestIndex and add(ptr)
struct MockPiece {
  TimeRange trange;
  MockPiece(double b, double e) : trange(b,e) {}
  TimeRange const& range() const { return trange; }
  TimeRange& range() { return trange; }
  void setRange(TimeRange const& r) { trange = r; }
  void syncPhi0(MockPiece const&) {}
  static std::string trajName() { return "MockPiece"; }
};
using PTraj = KinKal::PiecewiseTrajectory<MockPiece>;

// reference: the v3.8.0 linear scan, verbatim
size_t linearIndex(PTraj const& pt, double time) {
  auto const& pieces = pt.pieces();
  size_t retval;
  if(time <= pt.range().begin()){
    retval = 0;
  } else if(time >= pt.range().end()){
    retval = pieces.size()-1;
  } else {
    retval = 0;
    while(retval < pieces.size() && (!pieces[retval]->range().inRange(time)) && time > pieces[retval]->range().end()){
      retval++;
    }
    if(retval == pieces.size())throw std::range_error("Failed PTraj range search");
  }
  return retval;
}

PTraj makeTraj(std::mt19937_64& rng, size_t npieces, double zerofrac) {
  std::uniform_real_distribution<double> step(1e-3,50.0), u(0.0,1.0);
  double t = -1000.0*u(rng);
  PTraj pt;
  for(size_t i=0;i<npieces;++i){
    double dt = step(rng);
    pt.add(std::make_shared<MockPiece>(t,t+dt));
    t += dt;
  }
  // collapse some interior pieces to zero length (add() drops null pieces, so edit ranges in place)
  auto const& pcs = pt.pieces();
  for(size_t i=1;i+1<pcs.size();++i){
    if(u(rng) < zerofrac){
      double b = pcs[i]->range().begin();
      pcs[i]->range() = TimeRange(b,b);
      pcs[i+1]->range() = TimeRange(b,pcs[i+1]->range().end());
    }
  }
  return pt;
}

int main() {
  std::mt19937_64 rng(20261016);
  std::uniform_real_distribution<double> u(0.0,1.0);
  size_t ncheck(0), nfail(0);
  auto check = [&](PTraj const& pt, double time){
    ++ncheck;
    size_t a = linearIndex(pt,time), b = pt.nearestIndex(time);
    if(a != b){ if(nfail++ < 10) printf("MISMATCH n=%zu t=%.17g linear=%zu binary=%zu\n",pt.pieces().size(),time,a,b); }
  };
  for(size_t itraj=0; itraj<2000; ++itraj){
    size_t n = 1 + static_cast<size_t>(std::pow(10.0, 4.0*u(rng)));
    PTraj pt = makeTraj(rng, n, itraj%4==0 ? 0.0 : 0.05);
    auto r = pt.range();
    for(auto const& p : pt.pieces()){ check(pt,p->range().begin()); check(pt,p->range().end()); check(pt,std::nextafter(p->range().end(),-INFINITY)); check(pt,p->range().mid()); }
    for(int i=0;i<200;++i) check(pt, r.begin() - 10.0 + (r.range()+20.0)*u(rng));
    check(pt, r.begin()-1.0); check(pt, r.end()+1.0); check(pt, NAN);
  }
  printf("equivalence: %zu checks, %zu mismatches\n", ncheck, nfail);

  // timing on N pieces, uniform random query times
  for(size_t n : {10ul, 100ul, 1000ul, 10000ul, 157000ul}){
    PTraj pt = makeTraj(rng, n, 0.0);
    std::vector<double> times(n > 10000 ? 20000 : 200000);
    for(auto& t : times) t = pt.range().begin() + pt.range().range()*u(rng);
    size_t sa(0), sb(0);
    auto t0 = std::chrono::steady_clock::now();
    for(double t : times) sa += linearIndex(pt,t);
    auto t1 = std::chrono::steady_clock::now();
    for(double t : times) sb += pt.nearestIndex(t);
    auto t2 = std::chrono::steady_clock::now();
    double la = std::chrono::duration<double,std::nano>(t1-t0).count()/times.size();
    double lb = std::chrono::duration<double,std::nano>(t2-t1).count()/times.size();
    printf("N=%7zu  linear %10.1f ns/call  binary %7.1f ns/call  speedup %8.1fx  %s\n", n, la, lb, la/lb, sa==sb ? "same" : "DIFFERENT");
    if(sa != sb) ++nfail;
  }
  printf("%s\n", nfail == 0 ? "NEARESTINDEX_EQUIV_PASS" : "NEARESTINDEX_EQUIV_FAIL");
  return nfail == 0 ? 0 : 1;
}
