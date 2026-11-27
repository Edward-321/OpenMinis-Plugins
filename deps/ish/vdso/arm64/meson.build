# ARM64 guest VDSO must be a real Linux ELF, not an empty touch target.
# Install Homebrew llvm + lld and expose lld/bin in PATH on macOS CI.
clang = find_program('/usr/local/opt/llvm/bin/clang', '/opt/homebrew/opt/llvm/bin/clang', '/opt/local/bin/clang', 'clang', required: true)

vdso_compiler = [clang, '-target', 'aarch64-linux-gnu', '-fuse-ld=lld']
vdso = custom_target('vdso-arm64',
    input: ['vdso.S', 'vdso.c', 'vdso.lds'],
    output: 'libvdso.so.elf',
    command: vdso_compiler + [
        '-o', '@OUTPUT@', '@INPUT0@', '@INPUT1@',
        '-nostdlib', '-Wl,-T,@INPUT2@', '-Wl,--hash-style,sysv',
        '-Wl,-z,max-page-size=4096', '-Wl,-s', '-O2',
        '-shared', '-fPIC', '-ffreestanding'
    ] + get_option('vdso_c_args').split())
