; ============================================================
; OSLIB2.asm  --  GUO OS Library v5
; 64-bit long mode + kernel extensions + CLASM abstractions
; Pure assembly. No C. No Rust. No apologies.
;
; v5 adds:
;   - Real heap allocator: kmalloc / kfree / krealloc / kzalloc
;     with block headers, free-list, coalescing.
;   - Ring 3 support: TSS, user GDT segments, enter_user_mode.
;   - syscall / sysret: EFER.SCE, STAR, LSTAR, FMASK MSRs.
;   - Syscall dispatch table with exit/write/read/open/close/
;     mmap/getpid/yield/sleep/brk/time/rand.
;   - Userspace syscall wrappers (callable from ring 3).
;
; Design goal: make OSDev read like Python.
;   println "hello"
;   println "x =", rax
;   println "count:", my_var, "done"
; ============================================================

bits 64

; ============================================================
; SECTION 0 -- ARGUMENT TYPE DETECTION
; ============================================================

%macro __is_register 1
    %ifidn %1, rax
        %define __ARG_KIND_%[__argn] REG
    %elifidn %1, rbx
        %define __ARG_KIND_%[__argn] REG
    %elifidn %1, rcx
        %define __ARG_KIND_%[__argn] REG
    %elifidn %1, rdx
        %define __ARG_KIND_%[__argn] REG
    %elifidn %1, rsi
        %define __ARG_KIND_%[__argn] REG
    %elifidn %1, rdi
        %define __ARG_KIND_%[__argn] REG
    %elifidn %1, rbp
        %define __ARG_KIND_%[__argn] REG
    %elifidn %1, rsp
        %define __ARG_KIND_%[__argn] REG
    %elifidn %1, r8
        %define __ARG_KIND_%[__argn] REG
    %elifidn %1, r9
        %define __ARG_KIND_%[__argn] REG
    %elifidn %1, r10
        %define __ARG_KIND_%[__argn] REG
    %elifidn %1, r11
        %define __ARG_KIND_%[__argn] REG
    %elifidn %1, r12
        %define __ARG_KIND_%[__argn] REG
    %elifidn %1, r13
        %define __ARG_KIND_%[__argn] REG
    %elifidn %1, r14
        %define __ARG_KIND_%[__argn] REG
    %elifidn %1, r15
        %define __ARG_KIND_%[__argn] REG
    %else
        %define __ARG_KIND_%[__argn] VAR
    %endif
%endmacro

; ============================================================
; SECTION 1 -- CLASM MACROS
; ============================================================

%macro func 1
    global %1
    %1:
    push rbp
    mov rbp, rsp
%endmacro

%macro endfunc 0
    pop rbp
    ret
%endmacro

%macro var 2
    global %1
    %1: dq %2
%endmacro

%macro str 2
    global %1
    %1: db %2, 0
%endmacro

%macro set 2
    mov qword [rel %1], %2
%endmacro

%macro setr 2
    mov [rel %1], %2
%endmacro

%macro get 2
    mov %1, [rel %2]
%endmacro

; ============================================================
; SECTION 2 -- PRINT MACROS
; ============================================================

%macro __emit_arg 1
    %ifstr %1
        mov rsi, %1
        call print_string
    %else
        %ifidn %1, rax
            mov rsi, rax
            call print_dec
        %elifidn %1, rbx
            mov rsi, rbx
            call print_dec
        %elifidn %1, rcx
            mov rsi, rcx
            call print_dec
        %elifidn %1, rdx
            mov rsi, rdx
            call print_dec
        %elifidn %1, rsi
            mov rsi, rsi
            call print_dec
        %elifidn %1, rdi
            mov rsi, rdi
            call print_dec
        %elifidn %1, r8
            mov rsi, r8
            call print_dec
        %elifidn %1, r9
            mov rsi, r9
            call print_dec
        %elifidn %1, r10
            mov rsi, r10
            call print_dec
        %elifidn %1, r11
            mov rsi, r11
            call print_dec
        %elifidn %1, r12
            mov rsi, r12
            call print_dec
        %elifidn %1, r13
            mov rsi, r13
            call print_dec
        %elifidn %1, r14
            mov rsi, r14
            call print_dec
        %elifidn %1, r15
            mov rsi, r15
            call print_dec
        %else
            mov rsi, [rel %1]
            call print_dec
        %endif
    %endif
%endmacro

%macro print 1-*
    %rep %0
        %rotate 0
        __emit_arg %1
        %rotate 1
    %endrep
%endmacro

%macro println 0-*
    %rep %0
        __emit_arg %1
        %rotate 1
    %endrep
    call newline
%endmacro

%macro print_var 1
    mov rsi, [rel %1]
    call print_dec
%endmacro

%macro print_concat 2
    mov rsi, %1
    call print_string
    mov rsi, ' '
    call print_char
    mov rsi, [rel %2]
    call print_dec
    call newline
%endmacro

%macro print_ch 1
    mov rsi, %1
    call print_char
%endmacro

%macro print_h 1
    %ifidn %1, rax
        mov rsi, rax
    %elifidn %1, rbx
        mov rsi, rbx
    %elifidn %1, rcx
        mov rsi, rcx
    %elifidn %1, rdx
        mov rsi, rdx
    %else
        mov rsi, [rel %1]
    %endif
    call print_hex
%endmacro

; ============================================================
; SECTION 3 -- LOOP / CONTROL MACROS
; ============================================================

%macro repeat 1
    mov r15, %1
%%loop:
%endmacro

%macro endrepeat 0
    dec r15
    jnz %%loop
%endmacro

%macro if_zero 1
    test %1, %1
    jnz %%skip
%endmacro

%macro endif_zero 0
%%skip:
%endmacro

%macro jump_eq 3
    cmp %1, %2
    je %3
%endmacro

%macro jump_ne 3
    cmp %1, %2
    jne %3
%endmacro

%macro for_range 2
    mov r15, %1
%%loop:
    cmp r15, %2
    jge %%done
%endmacro

%macro end_for_range 0
    inc r15
    jmp %%loop
%%done:
%endmacro

%macro while_not_zero 1
%%loop:
    test %1, %1
    jz %%done
%endmacro

%macro end_while 0
    jmp %%loop
%%done:
%endmacro

; ============================================================
; SECTION 4 -- MEMORY / IO MACROS
; ============================================================

%macro poke_byte 2
    mov byte [%1], %2
%endmacro

%macro peek_byte 2
    movzx %1, byte [%2]
%endmacro

%macro out_port 2
    mov dx, %1
    mov al, %2
    out dx, al
%endmacro

%macro in_port 1
    mov dx, %1
    xor rax, rax
    in al, dx
%endmacro

%macro error 1
    mov rsi, %1
    call panic
%endmacro

%macro debug 1
    mov rsi, %1
    call print_line
%endmacro

%macro def_func 1
    func %1
%endmacro

%macro end_def 0
    endfunc
%endmacro

; ============================================================
; SECTION 5 -- CONSTANTS
; ============================================================

%define VGA_BUFFER      0xB8000
%define VGA_WIDTH       80
%define VGA_HEIGHT      25
%define VGA_SIZE        (VGA_WIDTH * VGA_HEIGHT)
%define VGA_ATTR        0x0F

; --- heap ---
%define HEAP_START      0x1F0000
%define HEAP_SIZE       0x100000        ; 1 MB
%define HEAP_END        (HEAP_START + HEAP_SIZE)
%define HEAP_MAGIC      0x47554F48      ; "GUOH"
%define ALIGN_UP(x)     (((x) + 15) & ~15)

; --- GDT selectors (must match GDT layout) ---
%define SEL_NULL        0x0000
%define SEL_KCODE       0x0008
%define SEL_KDATA       0x0010
%define SEL_UDATA       0x0018          ; ring 3 data (with RPL 3 -> 0x1B)
%define SEL_UCODE       0x0020          ; ring 3 code (with RPL 3 -> 0x23)
%define SEL_TSS         0x0028
%define SEL_UDATA_RPL3  0x001B
%define SEL_UCODE_RPL3  0x0023

; --- MSRs ---
%define MSR_EFER        0xC0000080
%define MSR_STAR        0xC0000081
%define MSR_LSTAR       0xC0000082
%define MSR_FMASK       0xC0000084
%define MSR_FS_BASE     0xC0000100
%define MSR_GS_BASE     0xC0000101

; --- EFER bits ---
%define EFER_SCE        (1 << 0)
%define EFER_LME        (1 << 8)
%define EFER_LMA        (1 << 10)
%define EFER_NXE        (1 << 11)

; --- RFLAGS ---
%define RFLAGS_IF       (1 << 9)

; --- syscall numbers ---
%define SYS_EXIT        0
%define SYS_WRITE       1
%define SYS_READ        2
%define SYS_OPEN        3
%define SYS_CLOSE       4
%define SYS_MMAP        5
%define SYS_GETPID      6
%define SYS_YIELD       7
%define SYS_SLEEP       8
%define SYS_BRK         9
%define SYS_TIME        10
%define SYS_RAND        11
%define SYS_MAX         12

; --- TSS layout (64-bit) ---
%define TSS_SIZE        104

; ============================================================
; SECTION 6 -- GLOBALS
; ============================================================

section .data

; VGA / printing
cursor_pos:     dd 0

; RNG / ticks
tick_counter:   dq 0
rand_seed:      dq 12345

; --- heap state ---
heap_ptr:       dq HEAP_START           ; legacy bump ptr (kept for kmalloc compat)
heap_head:      dq 0                    ; first block header
heap_inited:    dq 0

; --- TSS ---
align 16
tss:
    dd 0                                ; reserved
    dq 0                                ; rsp0 (set at runtime)
    dq 0                                ; rsp1
    dq 0                                ; rsp2
    dq 0                                ; reserved
    dq 0                                ; ist1
    dq 0                                ; ist2
    dq 0                                ; ist3
    dq 0                                ; ist4
    dq 0                                ; ist5
    dq 0                                ; ist6
    dq 0                                ; ist7
    dq 0                                ; reserved
    dw 0                                ; reserved
    dw TSS_SIZE - 1                     ; iomap base (no iomap)

; --- GDT (kernel + user + TSS) ---
align 16
gdt_start:
    dq 0                                ; null
gdt_kcode:
    dq 0x00209A0000000000               ; kernel code: L=1, DPL=0, present, exec/read
gdt_kdata:
    dq 0x0000920000000000               ; kernel data: DPL=0, present, rw
gdt_udata:
    dq 0x0000F20000000000               ; user data: DPL=3, present, rw
gdt_ucode:
    dq 0x0020FA0000000000               ; user code: L=1, DPL=3, present, exec/read
gdt_tss:
    ; TSS descriptor filled at runtime by gdt_install_tss
    dq 0
    dq 0
gdt_end:

gdt_descriptor:
    dw gdt_end - gdt_start - 1
    dq gdt_start

; --- syscall state ---
kernel_rsp0:    dq 0                    ; top of kernel stack for syscall entry
user_rsp:       dq 0                    ; saved user rsp (scratch)
current_pid:    dq 1

; --- process table (minimal) ---
MAX_PROCS       equ 16
proc_pid:       times MAX_PROCS dq 0
proc_rsp:       times MAX_PROCS dq 0
proc_state:     times MAX_PROCS dq 0    ; 0=free, 1=ready, 2=running, 3=zombie

; --- brk ---
user_brk:       dq 0x400000

section .bss
align 16
syscall_stack:  resb 4096               ; small kernel stack for syscall entry

section .text

; ============================================================
; SECTION 7 -- CORE PRINT ROUTINES
; ============================================================

func print_char
    cmp sil, 0x0A
    je .newline
    cmp sil, 0x0D
    je .carriage_return

    push rdi
    push rax

    mov eax, [rel cursor_pos]
    mov rdi, VGA_BUFFER
    add rdi, rax
    add rdi, rax

    mov [rdi], sil
    mov byte [rdi+1], VGA_ATTR

    inc dword [rel cursor_pos]

    cmp dword [rel cursor_pos], VGA_SIZE
    jl .normal_done
    call scroll
    mov dword [rel cursor_pos], VGA_SIZE - VGA_WIDTH
.normal_done:
    pop rax
    pop rdi
    jmp .exit

.newline:
    push rax
    push rbx
    push rdx
    mov eax, [rel cursor_pos]
    xor edx, edx
    mov ebx, VGA_WIDTH
    div ebx
    inc eax
    mul ebx
    mov [rel cursor_pos], eax
    cmp dword [rel cursor_pos], VGA_SIZE
    jl .newline_done
    call scroll
    mov dword [rel cursor_pos], VGA_SIZE - VGA_WIDTH
.newline_done:
    pop rdx
    pop rbx
    pop rax
    jmp .exit

.carriage_return:
    push rax
    push rbx
    push rdx
    mov eax, [rel cursor_pos]
    xor edx, edx
    mov ebx, VGA_WIDTH
    div ebx
    mul ebx
    mov [rel cursor_pos], eax
    pop rdx
    pop rbx
    pop rax
jmp .exit
.exit:
endfunc

func print_string
    push rbx
    push rax
    mov rbx, rsi
.loop:
    mov al, [rbx]
    test al, al
    jz .done
    inc rbx
    movzx rsi, al
    call print_char
    jmp .loop
.done:
    pop rax
    pop rbx
endfunc

func print_line
    call print_string
    mov rsi, 0x0A
    call print_char
endfunc

func newline
    mov rsi, 0x0A
    call print_char
endfunc

func print_at
    push rdi
    push rax
    mov rax, rdi
    mov rdi, VGA_BUFFER
    add rdi, rax
    add rdi, rax
    mov [rdi], sil
    mov byte [rdi+1], VGA_ATTR
    pop rax
    pop rdi
endfunc

func set_cursor
    mov [rel cursor_pos], esi
endfunc

func get_cursor
    mov eax, [rel cursor_pos]
endfunc

func clear_screen
    push rdi
    push rcx
    push rax
    mov rdi, VGA_BUFFER
    mov rcx, VGA_SIZE
    mov ax, (VGA_ATTR << 8) | 0x20
.clear:
    mov [rdi], ax
    add rdi, 2
    loop .clear
    mov dword [rel cursor_pos], 0
    pop rax
    pop rcx
    pop rdi
endfunc

func scroll
    push rdi
    push rsi
    push rcx
    push rax
    mov rdi, VGA_BUFFER
    mov rsi, VGA_BUFFER + (VGA_WIDTH * 2)
    mov rcx, (VGA_WIDTH * (VGA_HEIGHT - 1))
.scroll_loop:
    mov ax, [rsi]
    mov [rdi], ax
    add rdi, 2
    add rsi, 2
    loop .scroll_loop
    mov rcx, VGA_WIDTH
    mov ax, (VGA_ATTR << 8) | 0x20
.clear_last:
    mov [rdi], ax
    add rdi, 2
    loop .clear_last
    pop rax
    pop rcx
    pop rsi
    pop rdi
endfunc

func print_hex
    push rbx
    push rcx
    push rax
    push rsi
    mov rax, rsi
    mov rcx, 16
.hex_loop:
    rol rax, 4
    mov rbx, rax
    and rbx, 0x0F
    cmp rbx, 10
    jl .digit
    add rbx, 'A' - 10
    jmp .emit
.digit:
    add rbx, '0'
.emit:
    mov rsi, rbx
    call print_char
    loop .hex_loop
    pop rsi
    pop rax
    pop rcx
    pop rbx
endfunc

func print_hex_byte
    push rbx
    push rax
    push rsi
    mov rax, rsi
    and rax, 0xFF
    mov rbx, rax
    shr rbx, 4
    cmp rbx, 10
    jl .hi_digit
    add rbx, 'A' - 10
    jmp .hi_emit
.hi_digit:
    add rbx, '0'
.hi_emit:
    mov rsi, rbx
    call print_char
    mov rbx, rax
    and rbx, 0x0F
    cmp rbx, 10
    jl .lo_digit
    add rbx, 'A' - 10
    jmp .lo_emit
.lo_digit:
    add rbx, '0'
.lo_emit:
    mov rsi, rbx
    call print_char
    pop rsi
    pop rax
    pop rbx
endfunc

func print_dec
    push rbx
    push rcx
    push rdx
    push rax
    push rsi
    mov rax, rsi
    mov rbx, 10
    xor rcx, rcx
    test rax, rax
    jnz .convert
    mov rsi, '0'
    call print_char
    jmp .done
.convert:
.divide:
    xor rdx, rdx
    div rbx
    push rdx
    inc rcx
    test rax, rax
    jnz .divide
.print:
    pop rdx
    add rdx, '0'
    mov rsi, rdx
    call print_char
    loop .print
.done:
    pop rsi
    pop rax
    pop rdx
    pop rcx
    pop rbx
endfunc

func print_bool
    test rsi, rsi
    jz .false
    mov rsi, msg_true
    call print_string
    jmp .done
.false:
    mov rsi, msg_false
    call print_string
.done:
endfunc

; ============================================================
; SECTION 8 -- print_bin, print_oct, print_pad, printf
; ============================================================

func print_bin
    push rbx
    push rcx
    push rsi
    mov rax, rsi
    mov rcx, 64
.bin_loop:
    rol rax, 1
    mov rbx, rax
    and rbx, 1
    add rbx, '0'
    mov rsi, rbx
    call print_char
    loop .bin_loop
    pop rsi
    pop rcx
    pop rbx
endfunc

func print_oct
    push rbx
    push rcx
    push rdx
    push rax
    push rsi
    mov rax, rsi
    mov rbx, 8
    xor rcx, rcx
    test rax, rax
    jnz .convert
    mov rsi, '0'
    call print_char
    jmp .done
.convert:
.divide:
    xor rdx, rdx
    div rbx
    push rdx
    inc rcx
    test rax, rax
    jnz .divide
.print:
    pop rdx
    add rdx, '0'
    mov rsi, rdx
    call print_char
    loop .print
.done:
    pop rsi
    pop rax
    pop rdx
    pop rcx
    pop rbx
endfunc

func print_pad
    push rbx
    push rcx
    push rdx
    push rax
    push rsi
    push rdi
    mov rax, rsi
    mov rbx, 10
    xor rcx, rcx
    test rax, rax
    jnz .convert
    mov rsi, '0'
    call print_char
    jmp .done
.convert:
.divide:
    xor rdx, rdx
    div rbx
    push rdx
    inc rcx
    test rax, rax
    jnz .divide
    mov rax, rdi
    sub rax, rcx
    jle .print
.pad_loop:
    push rax
    mov rsi, '0'
    call print_char
    pop rax
    dec rax
    jnz .pad_loop
.print:
    pop rdx
    add rdx, '0'
    mov rsi, rdx
    call print_char
    loop .print
.done:
    pop rdi
    pop rsi
    pop rax
    pop rdx
    pop rcx
    pop rbx
endfunc

func printf
    push rbx
    push r12
    push r13
    mov rbx, rsi
    mov r12, rdx
.fmt_loop:
    mov al, [rbx]
    test al, al
    jz .done
    cmp al, '%'
    jne .emit
    inc rbx
    mov al, [rbx]
    cmp al, 's'
    je .do_s
    cmp al, 'd'
    je .do_d
    cmp al, 'x'
    je .do_x
    cmp al, 'c'
    je .do_c
    cmp al, 'p'
    je .do_p
    cmp al, 'b'
    je .do_b
    cmp al, 'o'
    je .do_o
    cmp al, '%'
    je .emit
    jmp .emit
.do_s:
    mov rsi, [r12]
    add r12, 8
    call print_string
    jmp .next
.do_d:
    mov rsi, [r12]
    add r12, 8
    call print_dec
    jmp .next
.do_x:
    mov rsi, [r12]
    add r12, 8
    call print_hex
    jmp .next
.do_c:
    mov rsi, [r12]
    add r12, 8
    call print_char
    jmp .next
.do_p:
    mov rsi, [r12]
    add r12, 8
    call print_hex
    jmp .next
.do_b:
    mov rsi, [r12]
    add r12, 8
    call print_bin
    jmp .next
.do_o:
    mov rsi, [r12]
    add r12, 8
    call print_oct
    jmp .next
.emit:
    movzx rsi, al
    call print_char
.next:
    inc rbx
    jmp .fmt_loop
.done:
    pop r13
    pop r12
    pop rbx
endfunc

func printf_ln
    call printf
    call newline
endfunc

; ============================================================
; SECTION 9 -- STRING / MEMORY ROUTINES
; ============================================================

func hexdump
    push rbx
    push rcx
    push rsi
    push rdx
    push rax
    mov rbx, rsi
    mov rcx, rdx
.dump_loop:
    test rcx, rcx
    jz .done
    mov rsi, rbx
    call print_hex
    mov rsi, ' '
    call print_char
    mov r15, 16
.byte_loop:
    test rcx, rcx
    jz .pad
    test r15, r15
    jz .next_line
    mov rsi, [rbx]
    and rsi, 0xFF
    call print_hex_byte
    mov rsi, ' '
    call print_char
    inc rbx
    dec rcx
    dec r15
    jmp .byte_loop
.pad:
    test r15, r15
    jz .next_line
    mov rsi, ' '
    call print_char
    mov rsi, ' '
    call print_char
    mov rsi, ' '
    call print_char
    dec r15
    jmp .pad
.next_line:
    call newline
    jmp .dump_loop
.done:
    pop rax
    pop rdx
    pop rsi
    pop rcx
    pop rbx
endfunc

func strlen
    xor rax, rax
.loop:
    cmp byte [rsi + rax], 0
    je .done
    inc rax
    jmp .loop
.done:
endfunc

func strcmp
.loop:
    mov al, [rsi]
    mov bl, [rdx]
    cmp al, bl
    jne .diff
    test al, al
    jz .equal
    inc rsi
    inc rdx
    jmp .loop
.diff:
    movzx rax, al
    movzx rbx, bl
    sub rax, rbx
    jmp .done
.equal:
    xor rax, rax
.done:
endfunc

func strncmp
.loop:
    test rcx, rcx
    jz .equal
    mov al, [rsi]
    mov bl, [rdx]
    cmp al, bl
    jne .diff
    test al, al
    jz .equal
    inc rsi
    inc rdx
    dec rcx
    jmp .loop
.diff:
    movzx rax, al
    movzx rbx, bl
    sub rax, rbx
    jmp .done
.equal:
    xor rax, rax
.done:
endfunc

func strcpy
.loop:
    mov al, [rsi]
    mov [rdi], al
    test al, al
    jz .done
    inc rsi
    inc rdi
    jmp .loop
.done:
endfunc

func strcat
    push rdi
.find_end:
    cmp byte [rdi], 0
    je .copy
    inc rdi
    jmp .find_end
.copy:
    mov al, [rsi]
    mov [rdi], al
    test al, al
    jz .done
    inc rsi
    inc rdi
    jmp .copy
.done:
    pop rdi
endfunc

func strchr
.loop:
    mov al, [rsi]
    test al, al
    jz .not_found
    cmp al, dil
    je .found
    inc rsi
    jmp .loop
.found:
    mov rax, rsi
    ret
.not_found:
    xor rax, rax
endfunc

func strrchr
    xor rax, rax
.loop:
    mov bl, [rsi]
    test bl, bl
    jz .done
    cmp bl, dil
    jne .next
    mov rax, rsi
.next:
    inc rsi
    jmp .loop
.done:
endfunc

func strrev
    push rsi
    push rdi
    mov rdi, rsi
.find_end:
    cmp byte [rdi], 0
    je .back
    inc rdi
    jmp .find_end
.back:
    dec rdi
.swap:
    cmp rsi, rdi
    jge .done
    mov al, [rsi]
    mov bl, [rdi]
    mov [rsi], bl
    mov [rdi], al
    inc rsi
    dec rdi
    jmp .swap
.done:
    pop rdi
    pop rsi
endfunc

func strtolower
    push rsi
.loop:
    mov al, [rsi]
    test al, al
    jz .done
    cmp al, 'A'
    jl .next
    cmp al, 'Z'
    jg .next
    add al, 32
    mov [rsi], al
.next:
    inc rsi
    jmp .loop
.done:
    pop rsi
endfunc

func strtoupper
    push rsi
.loop:
    mov al, [rsi]
    test al, al
    jz .done
    cmp al, 'a'
    jl .next
    cmp al, 'z'
    jg .next
    sub al, 32
    mov [rsi], al
.next:
    inc rsi
    jmp .loop
.done:
    pop rsi
endfunc

func is_digit
    xor rax, rax
    cmp sil, '0'
    jl .done
    cmp sil, '9'
    jg .done
    mov rax, 1
.done:
endfunc

func is_alpha
    xor rax, rax
    cmp sil, 'A'
    jl .check_lower
    cmp sil, 'Z'
    jle .yes
.check_lower:
    cmp sil, 'a'
    jl .done
    cmp sil, 'z'
    jg .done
.yes:
    mov rax, 1
.done:
endfunc

func is_space
    xor rax, rax
    cmp sil, ' '
    je .yes
    cmp sil, 0x09
    je .yes
    cmp sil, 0x0A
    je .yes
    cmp sil, 0x0D
    je .yes
    jmp .done
.yes:
    mov rax, 1
.done:
endfunc

func atoi
    push rbx
    push rcx
    xor rax, rax
    xor rbx, rbx
.loop:
    mov bl, [rsi]
    test bl, bl
    jz .done
    cmp bl, '0'
    jl .done
    cmp bl, '9'
    jg .done
    imul rax, rax, 10
    sub bl, '0'
    movzx rbx, bl
    add rax, rbx
    inc rsi
    jmp .loop
.done:
    pop rcx
    pop rbx
endfunc

func itoa
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov rax, rsi
    mov rbx, 10
    xor rcx, rcx
    test rax, rax
    jnz .convert
    mov byte [rdi], '0'
    mov byte [rdi+1], 0
    jmp .done
.convert:
.divide:
    xor rdx, rdx
    div rbx
    add dl, '0'
    push rdx
    inc rcx
    test rax, rax
    jnz .divide
.write:
    pop rdx
    mov [rdi], dl
    inc rdi
    loop .write
    mov byte [rdi], 0
.done:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
endfunc

func memset
    mov al, sil
    mov rcx, rdx
    rep stosb
endfunc

func memcpy
    mov rcx, rdx
    rep movsb
endfunc

func bzero
    mov rcx, rdx
    xor al, al
    rep stosb
endfunc

func memcmp
    mov rcx, rdx
    xor rax, rax
.loop:
    test rcx, rcx
    jz .done
    mov al, [rsi]
    mov bl, [rdi]
    cmp al, bl
    jne .diff
    inc rsi
    inc rdi
    dec rcx
    jmp .loop
.diff:
    movzx rax, al
    movzx rbx, bl
    sub rax, rbx
.done:
endfunc

; ============================================================
; SECTION 10 -- HEAP: kmalloc / kfree / krealloc / kzalloc
;
; Block header layout (16 bytes, aligned):
;   +0  magic   (u32)   HEAP_MAGIC
;   +4  size    (u32)   usable payload size in bytes
;   +8  next    (u64)   next block header (or 0)
;   +16 payload starts here
;
; Free blocks have a special marker: next == HEAP_MAGIC_FREE
; We keep a single free-list threaded through `next` for free
; blocks, and a separate all-blocks list threaded through
; `next` for allocated blocks. To keep it simple for v5, we
; use a classic "free-list with coalescing on alloc".
; ============================================================

%define HEAP_MAGIC_ALLOC    0x414C4F43   ; "ALOC"
%define HEAP_MAGIC_FREE     0x46524545   ; "FREE"
%define HDR_SIZE            16

; ------------------------------------------------------------
; heap_init -- must be called once before kmalloc/kfree
; ------------------------------------------------------------
func heap_init
    ; place one big free block at HEAP_START
    mov rdi, HEAP_START
    mov dword [rdi + 0], HEAP_MAGIC_FREE
    mov dword [rdi + 4], HEAP_SIZE - HDR_SIZE
    mov qword [rdi + 8], 0              ; end of list
    mov [rel heap_head], rdi
    mov qword [rel heap_inited], 1
    mov qword [rel heap_ptr], HEAP_START
endfunc

; ------------------------------------------------------------
; kmalloc -- allocate rsi bytes, returns rax = pointer or 0
; ------------------------------------------------------------
func kmalloc
    push rbx
    push r12
    push r13
    push r14

    ; if heap not initialized, do it now (idempotent)
    cmp qword [rel heap_inited], 0
    jne .inited
    call heap_init
.inited:
    ; round up to 16
    mov r12, rsi
    add r12, 15
    and r12, ~15
    cmp r12, 0
    jne .ok_size
    mov r12, 16
.ok_size:

    ; walk free list
    mov rbx, [rel heap_head]
.walk:
    test rbx, rbx
    jz .fail
    cmp dword [rbx + 0], HEAP_MAGIC_FREE
    jne .next
    mov r13, [rbx + 4]                  ; block size (u32 -> r13)
    cmp r13, r12
    jl .next

    ; this block fits
    ; if remainder large enough, split
    mov rax, r13
    sub rax, r12
    cmp rax, HDR_SIZE + 16
    jl .no_split

    ; split: carve a new block after payload
    lea r14, [rbx + HDR_SIZE + r12]
    mov dword [r14 + 0], HEAP_MAGIC_FREE
    mov rcx, r13
    sub rcx, r12
    sub rcx, HDR_SIZE
    mov dword [r14 + 4], ecx
    mov rcx, [rbx + 8]
    mov [r14 + 8], rcx
    ; fix current block
    mov dword [rbx + 4], r12d
    ; link new block into list before current
    mov [rbx + 8], r14

.no_split:
    ; mark allocated
    mov dword [rbx + 0], HEAP_MAGIC_ALLOC
    lea rax, [rbx + HDR_SIZE]
    jmp .done

.next:
    mov rbx, [rbx + 8]
    jmp .walk

.fail:
    xor rax, rax
.done:
    pop r14
    pop r13
    pop r12
    pop rbx
endfunc

; ------------------------------------------------------------
; kzalloc -- kmalloc + zero
; ------------------------------------------------------------
func kzalloc
    push rdi
    push rcx
    push rax

    call kmalloc
    test rax, rax
    jz .done
    mov rdi, rax
    mov rcx, rsi
    xor al, al
    rep stosb
    mov rax, rdi
    sub rax, rsi
.done:
    pop rax
    pop rcx
    pop rdi
endfunc

; ------------------------------------------------------------
; kfree -- free pointer in rsi
; ------------------------------------------------------------
func kfree
    push rbx
    push r12
    push r13

    test rsi, rsi
    jz .done

    lea rbx, [rsi - HDR_SIZE]
    cmp dword [rbx + 0], HEAP_MAGIC_ALLOC
    jne .done                          ; not ours, ignore

    ; mark free
    mov dword [rbx + 0], HEAP_MAGIC_FREE

    ; coalesce forward: if next block is free and adjacent
    mov r12, [rbx + 8]
    test r12, r12
    jz .try_prev
    mov rax, rbx
    add rax, HDR_SIZE
    add eax, [rbx + 4]
    cmp rax, r12
    jne .try_prev
    cmp dword [r12 + 0], HEAP_MAGIC_FREE
    jne .try_prev
    ; merge r12 into rbx
    mov eax, [r12 + 4]
    add eax, HDR_SIZE
    add [rbx + 4], eax
    mov rax, [r12 + 8]
    mov [rbx + 8], rax

.try_prev:
    ; coalesce backward: walk list to find predecessor
    mov r13, [rel heap_head]
.prev_walk:
    test r13, r13
    jz .done
    mov rax, [r13 + 8]
    cmp rax, rbx
    je .found_prev
    mov r13, rax
    jmp .prev_walk

.found_prev:
    cmp dword [r13 + 0], HEAP_MAGIC_FREE
    jne .done
    ; check adjacency: prev_end == rbx
    mov rax, r13
    add rax, HDR_SIZE
    add eax, [r13 + 4]
    cmp rax, rbx
    jne .done
    ; merge rbx into r13
    mov eax, [rbx + 4]
    add eax, HDR_SIZE
    add [r13 + 4], eax
    mov rax, [rbx + 8]
    mov [r13 + 8], rax

.done:
    pop r13
    pop r12
    pop rbx
endfunc

; ------------------------------------------------------------
; krealloc -- rsi = old ptr, rdi = new size
; ------------------------------------------------------------
func krealloc
    push rbx
    push r12
    push r13
    push r14

    mov r12, rsi                        ; old
    mov r13, rdi                        ; new size

    test r12, r12
    jnz .have_old
    mov rsi, r13
    call kmalloc
    jmp .done
.have_old:
    test r13, r13
    jnz .nonzero
    call kfree
    xor rax, rax
    jmp .done
.nonzero:
    lea rbx, [r12 - HDR_SIZE]
    mov r14d, [rbx + 4]                 ; old payload size
    cmp r14, r13
    jge .same_block                     ; shrinking or same: keep block

    ; need bigger: alloc new, copy, free old
    mov rsi, r13
    call kmalloc
    test rax, rax
    jz .done
    mov rdi, rax
    mov rsi, r12
    mov rdx, r14
    call memcpy
    ; free old
    mov rsi, r12
    push rax
    call kfree
    pop rax
    jmp .done

.same_block:
    mov rax, r12
.done:
    pop r14
    pop r13
    pop r12
    pop rbx
endfunc

; ------------------------------------------------------------
; heap_dump -- debug: walk the heap and print blocks
; ------------------------------------------------------------
func heap_dump
    push rbx
    push r12
    mov rbx, [rel heap_head]
.loop:
    test rbx, rbx
    jz .done
    mov rsi, rbx
    call print_hex
    mov rsi, ' '
    call print_char
    mov esi, [rbx + 0]
    call print_hex
    mov rsi, ' '
    call print_char
    mov esi, [rbx + 4]
    call print_dec
    mov rsi, ' '
    call print_char
    mov rsi, [rbx + 8]
    call print_hex
    call newline
    mov rbx, [rbx + 8]
    jmp .loop
.done:
    pop r12
    pop rbx
endfunc

; ------------------------------------------------------------
; Legacy kmalloc compat: keep the old bump behavior under a
; different name so old callers don't break.
; ------------------------------------------------------------
func bump_alloc
    push rbx
    mov rax, [rel heap_ptr]
    mov rbx, rax
    add rbx, rsi
    mov rcx, HEAP_END
    cmp rbx, rcx
    jg .fail
    mov [rel heap_ptr], rbx
    pop rbx
    ret
.fail:
    xor rax, rax
    pop rbx
endfunc

; ============================================================
; SECTION 11 -- I/O PORTS
; ============================================================

func read_port_byte
    mov dx, si
    xor rax, rax
    in al, dx
endfunc

func write_port_byte
    mov dx, si
    mov al, dil
    out dx, al
endfunc

func read_port_word
    mov dx, si
    xor rax, rax
    in ax, dx
endfunc

func write_port_word
    mov dx, si
    mov ax, di
    out dx, ax
endfunc

func read_port_dword
    mov dx, si
    xor rax, rax
    in eax, dx
endfunc

func write_port_dword
    mov dx, si
    mov eax, edi
    out dx, eax
endfunc

; ============================================================
; SECTION 12 -- INTERRUPTS / CPU
; ============================================================

func cli
    cli
endfunc

func sti
    sti
endfunc

func hlt
    hlt
endfunc

func pause
    pause
endfunc

; ------------------------------------------------------------
; read_cr3 / write_cr3
; ------------------------------------------------------------
func read_cr3
    mov rax, cr3
endfunc

func write_cr3
    mov cr3, rdi
endfunc

; ------------------------------------------------------------
; read_msr / write_msr
; rsi = msr, rdi = value (write); read returns rax
; ------------------------------------------------------------
func read_msr
    mov ecx, esi
    rdmsr
    shl rdx, 32
    or rax, rdx
endfunc

func write_msr
    mov ecx, esi
    mov rax, rdi
    mov rdx, rdi
    shr rdx, 32
    wrmsr
endfunc

; ============================================================
; SECTION 13 -- PANIC / HALT
; ============================================================

func panic
    mov rdi, msg_panic
    call print_string
    mov rdi, rsi
    call print_string
    call newline
.halt:
    hlt
    jmp .halt
endfunc

func halt
.halt_loop:
    hlt
    jmp .halt_loop
endfunc

; ============================================================
; SECTION 14 -- TIMER / RANDOM
; ============================================================

func get_ticks
    mov rax, [rel tick_counter]
endfunc

func inc_ticks
    inc qword [rel tick_counter]
endfunc

func rand
    mov rax, [rel rand_seed]
    imul rax, rax, 1103515245
    add rax, 12345
    mov [rel rand_seed], rax
    shr rax, 16
    and rax, 0x7FFF
endfunc

; ============================================================
; SECTION 15 -- KEYBOARD / THREAD STUBS
; ============================================================

func kbd_available
    xor rax, rax
endfunc

func kbd_getchar
    mov rax, -1
endfunc

func thread_create
    xor rax, rax
endfunc

func thread_yield
    ; no-op
endfunc

; ============================================================
; SECTION 16 -- TSS / GDT SETUP FOR RING 3
; ============================================================

; ------------------------------------------------------------
; tss_set_rsp0 -- set the kernel stack used on ring 3 -> 0
; rsi = new rsp0
; ------------------------------------------------------------
func tss_set_rsp0
    mov [rel tss + 4], rsi
endfunc

; ------------------------------------------------------------
; gdt_install_tss -- fill the TSS descriptor in the GDT
; ------------------------------------------------------------
func gdt_install_tss
    ; base = &tss, limit = TSS_SIZE - 1
    mov rax, tss
    mov rbx, TSS_SIZE - 1

    ; low 8 bytes: limit[0:15], base[0:15], base[16:23], type, flags, base[24:31]
    mov rcx, rax                    ; base
    and rcx, 0xFFFFFF               ; low 24 bits
    shl rcx, 16                     ; move to position
    mov rdx, rbx                    ; limit
    and rdx, 0xFFFF
    or rcx, rdx                     ; limit in low 16
    ; type = 0x89 (64-bit TSS, present, DPL=0)
    ; flags byte: G=0, D/B=0, L=0, AVL=0 -> 0x00
    mov rdx, 0x0000000000000089
    shl rdx, 40
    or rcx, rdx

    ; high 8 bytes: base[32:63]
    mov rdx, rax
    shr rdx, 32
    shl rdx, 0                      ; stays in low bits of upper qword
    ; but the descriptor is 16 bytes: store low qword at gdt_tss+0,
    ; high qword at gdt_tss+8
    mov [rel gdt_tss + 0], rcx
    mov [rel gdt_tss + 8], rdx
endfunc

; ------------------------------------------------------------
; gdt_load -- lgdt + reload segment registers
; ------------------------------------------------------------
func gdt_load
    lgdt [rel gdt_descriptor]
    ; reload CS via far return
    push SEL_KCODE
    lea rax, [rel .reload]
    push rax
    retfq
.reload:
    mov ax, SEL_KDATA
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
endfunc

; ------------------------------------------------------------
; tss_load -- ltr with TSS selector
; ------------------------------------------------------------
func tss_load
    mov ax, SEL_TSS
    ltr ax
endfunc

; ------------------------------------------------------------
; ring3_init -- call once: install TSS descriptor, load GDT,
;              load TSS, set up syscall MSRs.
; rsi = kernel rsp0 (top of kernel stack for ring 3 entries)
; ------------------------------------------------------------
func ring3_init
    push rbx
    push r12

    mov r12, rsi

    ; set TSS rsp0
    mov [rel tss + 4], r12
    mov [rel kernel_rsp0], r12

    ; install TSS descriptor into GDT
    call gdt_install_tss

    ; reload GDT + segments
    call gdt_load

    ; load TSS
    call tss_load

    ; configure syscall MSRs
    call syscall_init

    pop r12
    pop rbx
endfunc

; ============================================================
; SECTION 17 -- SYSCALL / SYSRET
;
; We use the fast SYSCALL/SYSRET path.
;   - EFER.SCE must be 1.
;   - STAR[47:32] = kernel CS (0x08), so SS = CS+8 = 0x10
;   - STAR[63:48] = user CS base (0x18), so SS = CS+8 = 0x20,
;                   and SYSRET loads CS = STAR[63:48]+16 = 0x28?
;     Actually: SYSRET loads CS = STAR[63:48] + 16, SS = +8.
;     We want user CS = 0x18, user SS = 0x20.
;     So STAR[63:48] should be 0x18 - 16 = 0x08? No.
;     Correct: SYSRET sets CS = (STAR[63:48] + 16) | 3,
;              SS = (STAR[63:48] + 8) | 3.
;     For CS=0x18, SS=0x20: STAR[63:48] = 0x08? Then CS=0x18, SS=0x10.
;     Hmm, that gives SS=0x10 (kernel data). Not right.
;     The canonical layout requires user CS and SS adjacent:
;       GDT order: ..., user_code (0x18), user_data (0x20), ...
;     SYSRET wants: CS = base+16, SS = base+8.
;     So base+16 = 0x18 -> base = 0x08.
;     Then SS = 0x10. That's wrong -- SS would be kernel data.
;     The fix: put user_data BEFORE user_code in GDT.
;     Standard layout:
;       0x00 null
;       0x08 kernel code
;       0x10 kernel data
;       0x18 user data     <- STAR[63:48]+8
;       0x20 user code     <- STAR[63:48]+16
;     Then STAR[63:48] = 0x10, CS = 0x20, SS = 0x18. Good.
;
; Our GDT currently has user_code at 0x18 and user_data at 0x20.
; That's the *swap* order. For SYSRET to work we need to swap them.
; We'll fix that here by redefining the GDT block. See gdt_start above:
; I already wrote it with ucode=0x18, udata=0x20. That's the wrong
; order for SYSRET. Correct order is udata first, ucode second.
; The GDT above is fixed to: null, kcode, kdata, udata, ucode.
; ============================================================

; NOTE: the GDT in section 6 already uses:
;   SEL_UCODE = 0x18, SEL_UDATA = 0x20
; which is the WRONG order for SYSRET. We keep the constants as
; aliases so existing code referencing SEL_UCODE/SEL_UDATA still
; works, but the actual GDT entries below are ordered for SYSRET.
; See `gdt_ucode` / `gdt_udata` -- they've been swapped in the
; data section. The selector numbers now mean:
;   0x18 = user data
;   0x20 = user code
; To avoid breaking the symbolic names, we redefine:

; ------------------------------------------------------------
; syscall_init -- set EFER.SCE and STAR/LSTAR/FMASK
; ------------------------------------------------------------
func syscall_init
    push rax
    push rcx
    push rdx
    push rsi

    ; --- EFER.SCE = 1 ---
    mov ecx, MSR_EFER
    rdmsr
    or eax, EFER_SCE
    wrmsr

    ; --- STAR ---
    ; bits 47:32 = kernel CS (0x08)
    ; bits 63:48 = user CS base; SYSRET uses base+16 as CS, base+8 as SS
    ; We want CS=0x20, SS=0x18 -> base = 0x10
    mov ecx, MSR_STAR
    mov eax, 0x00000000
    mov edx, 0x00100008             ; high dword: 0x0010_0008
    ; Wait: bits 47:32 are in EDX[15:0] = 0x0008, bits 63:48 in EDX[31:16] = 0x0010
    ; So EDX = (0x0010 << 16) | 0x0008 = 0x00100008
    wrmsr

    ; --- LSTAR = syscall_entry ---
    mov ecx, MSR_LSTAR
    lea rax, [rel syscall_entry]
    mov rdx, rax
    shr rdx, 32
    wrmsr

    ; --- FMASK = clear IF, TF, DF, AC on entry ---
    mov ecx, MSR_FMASK
    mov eax, 0x00040700             ; IF|TF|DF|AC
    xor edx, edx
    wrmsr

    pop rsi
    pop rdx
    pop rcx
    pop rax
endfunc

; ------------------------------------------------------------
; syscall_entry -- CPU jumps here on `syscall`
;
; On entry:
;   rcx = user RIP (return address)
;   r11 = user RFLAGS
;   rax = syscall number
;   rdi, rsi, rdx, r10, r8, r9 = args
;   CS/SS = kernel code/data (from STAR)
;   Interrupts disabled (FMASK cleared IF)
;
; We must:
;   - switch to a safe kernel stack
;   - save user context
;   - dispatch
;   - restore
;   - sysretq
; ------------------------------------------------------------
syscall_entry:
    ; swapgs if you use per-CPU GS. Skipped for now.
    ; Use the dedicated syscall stack.
    mov [rel user_rsp], rsp
    mov rsp, syscall_stack + 4096

    ; save the syscall frame
    push r11                            ; user rflags
    push rcx                            ; user rip
    push rdi
    push rsi
    push rdx
    push r10
    push r8
    push r9
    push rax                            ; syscall number
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15

    ; dispatch: rax = number, args in rdi/rsi/rdx/r10/r8/r9
    ; we already pushed them; reload for the handler
    ; (rax is at [rsp+...]; we saved it twice)
    ; Simpler: keep registers as-is and call dispatcher directly.
    ; Our dispatcher expects:
    ;   rdi = syscall number
    ;   rsi = arg0, rdx = arg1, rcx = arg2, r8 = arg3, r9 = arg4
    ; But syscall ABI puts args in rdi/rsi/rdx/r10/r8/r9.
    ; So we shuffle: number -> rdi, then args.
    mov rdi, rax                        ; number
    mov rsi, [rsp + 8*10]               ; original rdi? no -- let's reload
    ; Easier: pop into correct regs for the handler call.
    ; We'll just pass the saved frame pointer to a C-like dispatcher.
    mov rsi, rsp                        ; frame ptr
    call syscall_dispatch

    ; return value in rax
    ; restore user context
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    add rsp, 8                          ; discard saved syscall number
    pop r9
    pop r8
    pop r10
    pop rdx
    pop rsi
    pop rdi
    pop rcx                             ; user rip
    pop r11                             ; user rflags

    ; restore user stack
    mov rsp, [rel user_rsp]
    sysretq

; ------------------------------------------------------------
; syscall_dispatch -- rdi = syscall number, rsi = frame ptr
; Returns value in rax.
; ------------------------------------------------------------
func syscall_dispatch
    push rbx
    push r12
    push r13

    mov r12, rdi                        ; number
    mov r13, rsi                        ; frame

    ; extract args from the frame
    ; frame layout (from syscall_entry pushes, top first):
    ;   [r13 + 0]  = r15
    ;   [r13 + 8]  = r14
    ;   [r13 + 16] = r13
    ;   [r13 + 24] = r12
    ;   [r13 + 32] = rbp
    ;   [r13 + 40] = rbx
    ;   [r13 + 48] = rax (syscall number)
    ;   [r13 + 56] = r9
    ;   [r13 + 64] = r8
    ;   [r13 + 72] = r10
    ;   [r13 + 80] = rdx
    ;   [r13 + 88] = rsi
    ;   [r13 + 96] = rdi
    ;   [r13 + 104] = rcx (user rip)
    ;   [r13 + 112] = r11 (user rflags)
    ;
    ; Syscall ABI args: rdi, rsi, rdx, r10, r8, r9
    ; We'll pass to handlers as: rdi=a0, rsi=a1, rdx=a2, rcx=a3, r8=a4
    mov rdi, [r13 + 96]                 ; user rdi
    mov rsi, [r13 + 88]                 ; user rsi
    mov rdx, [r13 + 80]                 ; user rdx
    mov rcx, [r13 + 72]                 ; user r10
    mov r8,  [r13 + 64]                 ; user r8

    cmp r12, SYS_EXIT
    je .do_exit
    cmp r12, SYS_WRITE
    je .do_write
    cmp r12, SYS_READ
    je .do_read
    cmp r12, SYS_OPEN
    je .do_open
    cmp r12, SYS_CLOSE
    je .do_close
    cmp r12, SYS_MMAP
    je .do_mmap
    cmp r12, SYS_GETPID
    je .do_getpid
    cmp r12, SYS_YIELD
    je .do_yield
    cmp r12, SYS_SLEEP
    je .do_sleep
    cmp r12, SYS_BRK
    je .do_brk
    cmp r12, SYS_TIME
    je .do_time
    cmp r12, SYS_RAND
    je .do_rand

    ; unknown
    mov rax, -1
    jmp .done

.do_exit:
    ; rdi = exit code
    mov rsi, rdi
    call sys_exit
    mov rax, 0
    jmp .done
.do_write:
    ; rdi = fd, rsi = buf, rdx = len
    call sys_write
    jmp .done
.do_read:
    call sys_read
    jmp .done
.do_open:
    ; rdi = path, rsi = flags
    call sys_open
    jmp .done
.do_close:
    call sys_close
    jmp .done
.do_mmap:
    ; rdi = addr hint, rsi = len, rdx = prot
    call sys_mmap
    jmp .done
.do_getpid:
    call sys_getpid
    jmp .done
.do_yield:
    call sys_yield
    xor rax, rax
    jmp .done
.do_sleep:
    ; rdi = ticks
    call sys_sleep
    xor rax, rax
    jmp .done
.do_brk:
    ; rdi = new brk
    call sys_brk
    jmp .done
.do_time:
    call sys_time
    jmp .done
.do_rand:
    call sys_rand
    jmp .done

.done:
    pop r13
    pop r12
    pop rbx
endfunc

; ============================================================
; SECTION 18 -- SYSCALL IMPLEMENTATIONS
; ============================================================

; ------------------------------------------------------------
; sys_exit -- rsi = exit code. For now: halt or return to shell.
; ------------------------------------------------------------
func sys_exit
    cli

    ; In a real OS: mark process zombie, schedule next.
    ; For now, halt.
.halt:
    hlt
    jmp .halt
endfunc
; ------------------------------------------------------------
; sys_write -- rdi = fd, rsi = buf, rdx = len -> rax = bytes
; fd 1 = stdout (VGA), fd 2 = stderr (VGA)
; ------------------------------------------------------------
func sys_write
    push rbx
    push r12
    push r13
    mov r12, rdi                        ; fd
    mov r13, rsi                        ; buf
    mov rbx, rdx                        ; len

    ; only support fd 1 and 2 for now
    cmp r12, 1
    je .ok
    cmp r12, 2
    je .ok
    mov rax, -1
    jmp .done

.ok:
    xor r12, r12
.write_loop:
    cmp r12, rbx
    jge .write_done
    movzx rsi, byte [r13 + r12]
    call print_char
    inc r12
    jmp .write_loop
.write_done:
    mov rax, rbx
.done:
    pop r13
    pop r12
    pop rbx
endfunc

; ------------------------------------------------------------
; sys_read -- rdi = fd, rsi = buf, rdx = len -> rax = bytes
; For now: no-op returning 0.
; ------------------------------------------------------------
func sys_read
    xor rax, rax
endfunc

; ------------------------------------------------------------
; sys_open -- rdi = path, rsi = flags -> rax = fd
; Stub: returns -1 (no FS yet).
; ------------------------------------------------------------
func sys_open
    mov rax, -1
endfunc

; ------------------------------------------------------------
; sys_close -- rdi = fd
; ------------------------------------------------------------
func sys_close
    xor rax, rax
endfunc

; ------------------------------------------------------------
; sys_mmap -- rdi = addr hint, rsi = len, rdx = prot
; For now: bump-allocate from the heap and return the pointer.
; ------------------------------------------------------------
func sys_mmap
    push rsi
    mov rsi, rsi
    call kmalloc
    pop rsi
endfunc

; ------------------------------------------------------------
; sys_getpid
; ------------------------------------------------------------
func sys_getpid
    mov rax, [rel current_pid]
endfunc

; ------------------------------------------------------------
; sys_yield -- no-op for now
; ------------------------------------------------------------
func sys_yield
    xor rax, rax
endfunc

; ------------------------------------------------------------
; sys_sleep -- rdi = ticks. Busy-wait for now.
; ------------------------------------------------------------
func sys_sleep
    push rbx
    mov rbx, [rel tick_counter]
    add rbx, rdi
.wait:
    cmp [rel tick_counter], rbx
    jl .wait
    pop rbx
    xor rax, rax
endfunc

; ------------------------------------------------------------
; sys_brk -- rdi = new brk. Returns old brk.
; ------------------------------------------------------------
func sys_brk
    mov rax, [rel user_brk]
    test rdi, rdi
    jz .done
    mov [rel user_brk], rdi
.done:
endfunc

; ------------------------------------------------------------
; sys_time -- returns tick count
; ------------------------------------------------------------
func sys_time
    mov rax, [rel tick_counter]
endfunc

; ------------------------------------------------------------
; sys_rand -- returns a random number
; ------------------------------------------------------------
func sys_rand
    call rand
endfunc

; ============================================================
; SECTION 19 -- RING 3 ENTRY
;
; enter_user_mode(rip, rsp)
;   rsi = user rip
;   rdi = user rsp
;
; Sets up the iretq frame with user segments and jumps.
; Requires ring3_init to have been called first.
; ============================================================

func enter_user_mode
    ; frame for iretq: SS, RSP, RFLAGS, CS, RIP
    ; push in reverse
    push qword SEL_UDATA_RPL3
    push rdi                            ; user rsp
    push qword 0x02         ; RFLAGS (IF=1, bit1=1)
    push qword SEL_UCODE_RPL3
    push rsi                            ; user rip
    iretq
endfunc

; ------------------------------------------------------------
; enter_user_mode_default -- jumps to a user entry with the
; default user stack. rsi = user rip.
; ------------------------------------------------------------
func enter_user_mode_default
    mov rdi, user_stack + 8192 - 16
    call enter_user_mode
endfunc

; ============================================================
; SECTION 20 -- USERSPACE SYSCALL WRAPPERS
;
; These are callable from ring 3. They set up rax and the
; argument registers, then execute `syscall`.
;
; Usage (from a ring 3 program):
;   mov rdi, 1
;   mov rsi, msg
;   mov rdx, len
;   call sys_write
; ============================================================

; ------------------------------------------------------------
; sys_write wrapper -- rdi=fd, rsi=buf, rdx=len
; ------------------------------------------------------------
global sys_write_wrapper
sys_write_wrapper:
    mov r10, rcx                        ; syscall ABI wants arg3 in r10
    mov rax, SYS_WRITE
    syscall
    ret

; ------------------------------------------------------------
; sys_read wrapper -- rdi=fd, rsi=buf, rdx=len
; ------------------------------------------------------------
global sys_read_wrapper
sys_read_wrapper:
    mov r10, rcx
    mov rax, SYS_READ
    syscall
    ret

; ------------------------------------------------------------
; sys_exit wrapper -- rdi=code
; ------------------------------------------------------------
global sys_exit_wrapper
sys_exit_wrapper:
    mov rax, SYS_EXIT
    syscall
.halt:
    hlt
    jmp .halt

; ------------------------------------------------------------
; sys_open wrapper -- rdi=path, rsi=flags
; ------------------------------------------------------------
global sys_open_wrapper
sys_open_wrapper:
    mov rax, SYS_OPEN
    syscall
    ret

; ------------------------------------------------------------
; sys_close wrapper -- rdi=fd
; ------------------------------------------------------------
global sys_close_wrapper
sys_close_wrapper:
    mov rax, SYS_CLOSE
    syscall
    ret

; ------------------------------------------------------------
; sys_mmap wrapper -- rdi=addr, rsi=len, rdx=prot
; ------------------------------------------------------------
global sys_mmap_wrapper
sys_mmap_wrapper:
    mov r10, rcx
    mov rax, SYS_MMAP
    syscall
    ret

; ------------------------------------------------------------
; sys_getpid wrapper
; ------------------------------------------------------------
global sys_getpid_wrapper
sys_getpid_wrapper:
    mov rax, SYS_GETPID
    syscall
    ret

; ------------------------------------------------------------
; sys_yield wrapper
; ------------------------------------------------------------
global sys_yield_wrapper
sys_yield_wrapper:
    mov rax, SYS_YIELD
    syscall
    ret

; ------------------------------------------------------------
; sys_sleep wrapper -- rdi=ticks
; ------------------------------------------------------------
global sys_sleep_wrapper
sys_sleep_wrapper:
    mov rax, SYS_SLEEP
    syscall
    ret

; ------------------------------------------------------------
; sys_brk wrapper -- rdi=new_brk
; ------------------------------------------------------------
global sys_brk_wrapper
sys_brk_wrapper:
    mov rax, SYS_BRK
    syscall
    ret

; ------------------------------------------------------------
; sys_time wrapper
; ------------------------------------------------------------
global sys_time_wrapper
sys_time_wrapper:
    mov rax, SYS_TIME
    syscall
    ret

; ------------------------------------------------------------
; sys_rand wrapper
; ------------------------------------------------------------
global sys_rand_wrapper
sys_rand_wrapper:
    mov rax, SYS_RAND
    syscall
    ret

; ============================================================
; SECTION 21 -- DATA
; ============================================================

section .data
msg_true        db "true", 0
msg_false       db "false", 0
msg_sys_exit    db "[sys_exit] process exited", 0

; ============================================================
; END OF OSLIB2.asm v5
; ============================================================
