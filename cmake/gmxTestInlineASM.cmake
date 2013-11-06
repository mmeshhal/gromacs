# - Define macro to check GCC x86 inline ASM support
#
#  GMX_TEST_INLINE_ASM_GCC_X86(VARIABLE)
#
#  VARIABLE will be set to true if GCC x86 inline asm works.

MACRO(GMX_TEST_INLINE_ASM_GCC_X86 VARIABLE)
    IF(NOT DEFINED ${VARIABLE})
        
        MESSAGE(STATUS "Checking for GCC x86 inline asm")

        TRY_COMPILE(${VARIABLE} "${CMAKE_BINARY_DIR}"    
                    "${CMAKE_SOURCE_DIR}/cmake/TestInlineASM_gcc_x86.c"
                    OUTPUT_VARIABLE INLINE_ASM_COMPILE_OUTPUT)

        if(${VARIABLE})
            MESSAGE(STATUS "Checking for GCC x86 inline asm - supported")
            set(${VARIABLE} 1 CACHE INTERNAL "Result of test for GCC x86 inline asm" FORCE)
        else(${VARIABLE})
            MESSAGE(STATUS "Checking for GCC x86 inline asm - not supported")
            set(${VARIABLE} 0 CACHE INTERNAL "Result of test for GCC x86 inline asm" FORCE)
      	endif(${VARIABLE})

    ENDIF(NOT DEFINED ${VARIABLE})
ENDMACRO(GMX_TEST_INLINE_ASM_GCC_X86 VARIABLE)




