#include <thread>
long x = 0;
int main() { std::thread a([] { for (int i = 0; i < 100000; ++i) ++x; });
             for (int i = 0; i < 100000; ++i) ++x; a.join(); return x == 0; }
