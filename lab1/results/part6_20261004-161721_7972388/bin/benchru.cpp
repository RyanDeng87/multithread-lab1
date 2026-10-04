#include <cstdio>
#include <cstdlib>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>
int main(int, char** argv)
{
    const char* bin = std::getenv("BENCH_BIN");
    if (!bin) return 2;
    pid_t p = fork();
    if (p == 0) { argv[0] = const_cast<char*>(bin); execv(bin, argv); _exit(127); }
    int st = 0;
    waitpid(p, &st, 0);
    rusage r{};
    getrusage(RUSAGE_CHILDREN, &r);
    std::fprintf(stderr, "rusage: voluntary_cs=%ld involuntary_cs=%ld user_s=%.2f sys_s=%.2f\n",
                 r.ru_nvcsw, r.ru_nivcsw,
                 r.ru_utime.tv_sec + r.ru_utime.tv_usec / 1e6,
                 r.ru_stime.tv_sec + r.ru_stime.tv_usec / 1e6);
    return WIFEXITED(st) ? WEXITSTATUS(st) : 1;
}
