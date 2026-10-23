import Darwin

/// Whether the tests run translated by Rosetta: CI's x86_64 job runs the tests on Apple Silicon, where the
/// GitHub virtual machines give translated code no hardware video decoder. The tests that need one run on Intel Macs.
let runsUnderRosetta: Bool = {
    var translated: Int32 = 0, size = MemoryLayout<Int32>.size
    return sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0 && translated == 1
}()
