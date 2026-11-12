# Used by tools/build_satdump.sh. Newer Xcode no longer brings in the C standard headers indirectly, and some
# SatDump files rely on that. SatDump's CMake sets its own compiler flags, so the headers are added here,
# after each project() call, where they can't be overwritten.
add_compile_options("$<$<COMPILE_LANGUAGE:CXX>:SHELL:-include cstdlib>"
                    "$<$<COMPILE_LANGUAGE:CXX>:SHELL:-include cstring>"
                    "$<$<COMPILE_LANGUAGE:CXX>:SHELL:-include cstdint>")
