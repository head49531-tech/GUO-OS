; Kernel_S1.asm
; GUO OS kernel - stage 1
; Built with -f elf64 + linker script at 0x100000.
;
; v2: ring 3 setup, syscall MSRs, user program entry.
; All print/string/port/panic/CLASM routines now live in
; OSLIB2.asm and are included via %include. This file only
; defines kernel-specific state and hardware setup.

bits 64

jmp kernel_main

; ============================================================
; CONSTANTS
; ============================================================

%define VGA_BUFFER      0xB8000
%define VGA_WIDTH       80
%define VGA_HEIGHT      25
%define VGA_SIZE        (VGA_WIDTH * VGA_HEIGHT)
%define VGA_ATTR        0x0F

%define PIC1_CMD        0x20
%define PIC1_DATA       0x21
%define PIC2_CMD        0xA0
%define PIC2_DATA       0xA1
%define PIC_EOI         0x20

%define KEYBOARD_DATA   0x60
%define KEYBOARD_STATUS 0x64
%define MOUSE_DATA      0x60
%define MOUSE_STATUS    0x64
%define MOUSE_CMD       0x64

%define PIT_CHANNEL0    0x40
%define PIT_CMD         0x43
%define PIT_FREQ        1193182
%define TARGET_FREQ     100

; ============================================================
; GLOBALS
; ============================================================

section .data

tick_count:         dq 0
keyboard_buffer:    times 256 db 0
keyboard_head:      dd 0
keyboard_tail:      dd 0
mouse_x:            dd 40
mouse_y:            dd 12
mouse_cycle:        dd 0
mouse_bytes:        times 3 db 0
debug_stage:        dd 0

shift_pressed:      db 0
ctrl_pressed:       db 0
line_buffer:        times 256 db 0
line_length:        dd 0

; --- user program entry point (set at runtime) ---
user_program_entry: dq 0

section .bss
align 16

; --- kernel stack used for ring 3 -> ring 0 transitions ---
; This is what tss.rsp0 points at. Must be 16-byte aligned.
kernel_stack:       resb 16384
kernel_stack_top:

; --- user program stack (ring 3) ---
user_stack:         resb 16384
user_stack_top:

; --- a tiny user program blob, loaded into memory at runtime ---
; We'll copy this into a page-aligned region and jump to it.
user_program_blob:  resb 4096

section .text

; ============================================================
; INTERRUPT STUBS AND HANDLERS
; ============================================================

%macro ISR_NOERR 1
global isr%1
isr%1:
    cli
    push qword 0
    push qword %1
    jmp isr_common
%endmacro

%macro ISR_ERR 1
global isr%1
isr%1:
    cli
    push qword %1
    jmp isr_common
%endmacro

%macro IRQ 2
global irq%1
irq%1:
    cli
    push qword 0
    push qword %2
    jmp irq_common
%endmacro

ISR_NOERR 0
ISR_NOERR 1
ISR_NOERR 2
ISR_NOERR 3
ISR_NOERR 4
ISR_NOERR 5
ISR_NOERR 6
ISR_NOERR 7
ISR_ERR   8
ISR_NOERR 9
ISR_ERR   10
ISR_ERR   11
ISR_ERR   12
ISR_ERR   13
ISR_ERR   14
ISR_NOERR 15
ISR_NOERR 16
ISR_ERR   17
ISR_NOERR 18
ISR_NOERR 19
ISR_NOERR 20
ISR_NOERR 21
ISR_NOERR 22
ISR_NOERR 23
ISR_NOERR 24
ISR_NOERR 25
ISR_NOERR 26
ISR_NOERR 27
ISR_NOERR 28
ISR_NOERR 29
ISR_ERR   30
ISR_NOERR 31

IRQ 0, 32
IRQ 1, 33
IRQ 2, 34
IRQ 3, 35
IRQ 4, 36
IRQ 5, 37
IRQ 6, 38
IRQ 7, 39
IRQ 8, 40
IRQ 9, 41
IRQ 10, 42
IRQ 11, 43
IRQ 12, 44
IRQ 13, 45
IRQ 14, 46
IRQ 15, 47

isr_common:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    mov rdi, rsp
    call isr_handler
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    add rsp, 16
    iretq

irq_common:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    mov rdi, rsp
    call irq_handler
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    add rsp, 16
    iretq

; ============================================================
; ISR HANDLER
; ============================================================

isr_handler:
    push rbx
    mov rbx, rdi
    mov rsi, msg_exception
    call print_string
    mov rsi, [rbx + 120]
    call print_dec
    mov rsi, msg_err
    call print_string
    mov rsi, [rbx + 128]
    call print_hex
    call newline

    mov rsi, [rbx + 120]
    cmp rsi, 0
    je .div_zero
    cmp rsi, 6
    je .inv_opcode
    cmp rsi, 13
    je .gpf
    cmp rsi, 14
    je .page_fault
    jmp .halt

.div_zero:
    mov rsi, msg_div_zero
    call print_line
    jmp .halt
.inv_opcode:
    mov rsi, msg_inv_opcode
    call print_line
    jmp .halt
.gpf:
    mov rsi, msg_gpf
    call print_line
    mov rsi, msg_fault_addr
    call print_string
    mov rsi, [rbx + 136]
    call print_hex
    call newline
    jmp .halt
.page_fault:
    mov rsi, msg_page_fault
    call print_line
    mov rsi, msg_fault_addr
    call print_string
    mov rsi, cr2
    mov rsi, rax
    call print_hex
    call newline
    jmp .halt
.halt:
    mov rsi, msg_halted
    call print_line
.halt_loop:
    hlt
    jmp .halt_loop

; ============================================================
; IRQ HANDLER
; ============================================================

irq_handler:
    push rbx
    mov rbx, rdi
    mov rax, [rbx + 120]
    sub rax, 32
    cmp rax, 0
    je .timer
    cmp rax, 1
    je .keyboard
    cmp rax, 12
    je .mouse
    jmp .eoi

.timer:
    inc qword [rel tick_count]
    jmp .eoi

.keyboard:
    xor rax, rax
    in al, KEYBOARD_DATA
    mov bl, al

    cmp bl, 0x2A
    je .shift_on
    cmp bl, 0x36
    je .shift_on
    cmp bl, 0xAA
    je .shift_off
    cmp bl, 0xB6
    je .shift_off
    cmp bl, 0x1D
    je .ctrl_on
    cmp bl, 0x9D
    je .ctrl_off
    cmp bl, 0x48
    je .keyboard_done
    cmp bl, 0x50
    je .keyboard_done
    cmp bl, 0x4B
    je .keyboard_done
    cmp bl, 0x4D
    je .keyboard_done
    cmp bl, 0x0E
    je .backspace_key
    cmp bl, 0x1C
    je .enter_key

    test bl, 0x80
    jnz .keyboard_done

    movzx rax, bl
    cmp byte [rel shift_pressed], 0
    jne .use_shift_table
    mov rsi, [rel keyboard_table + rax]
    jmp .got_char
.use_shift_table:
    mov rsi, [rel keyboard_table_shift + rax]
.got_char:
    test rsi, rsi
    jz .keyboard_done
    cmp byte [rel ctrl_pressed], 0
    jne .keyboard_done

    mov eax, [rel keyboard_head]
    mov [rel keyboard_buffer + rax], sil
    inc eax
    and eax, 255
    mov [rel keyboard_head], eax

    mov eax, [rel line_length]
    cmp eax, 255
    jge .keyboard_done
    mov [rel line_buffer + rax], sil
    inc eax
    mov [rel line_length], eax

    call print_char
    jmp .keyboard_done

.shift_on:
    mov byte [rel shift_pressed], 1
    jmp .keyboard_done
.shift_off:
    mov byte [rel shift_pressed], 0
    jmp .keyboard_done
.ctrl_on:
    mov byte [rel ctrl_pressed], 1
    jmp .keyboard_done
.ctrl_off:
    mov byte [rel ctrl_pressed], 0
    jmp .keyboard_done

.backspace_key:
    cmp dword [rel line_length], 0
    je .keyboard_done
    dec dword [rel line_length]
    call backspace
    jmp .keyboard_done

.enter_key:
    mov eax, [rel line_length]
    mov byte [rel line_buffer + rax], 0
    call newline

    call shell_handle_line

    mov dword [rel line_length], 0
    call shell_prompt
    jmp .keyboard_done

.keyboard_done:
    jmp .eoi

.mouse:
    xor rax, rax
    in al, MOUSE_DATA
    mov bl, al
    mov eax, [rel mouse_cycle]
    mov [rel mouse_bytes + rax], bl
    inc eax
    cmp eax, 3
    jl .mouse_store
    xor eax, eax
.mouse_store:
    mov [rel mouse_cycle], eax
    test eax, eax
    jnz .mouse_done
    mov al, [rel mouse_bytes + 1]
    mov bl, [rel mouse_bytes + 2]
    movsx eax, al
    add [rel mouse_x], eax
    movsx eax, bl
    sub [rel mouse_y], eax
    cmp dword [rel mouse_x], 0
    jge .x_ok
    mov dword [rel mouse_x], 0
.x_ok:
    cmp dword [rel mouse_x], 79
    jle .x_ok2
    mov dword [rel mouse_x], 79
.x_ok2:
    cmp dword [rel mouse_y], 0
    jge .y_ok
    mov dword [rel mouse_y], 0
.y_ok:
    cmp dword [rel mouse_y], 24
    jle .y_ok2
    mov dword [rel mouse_y], 24
.y_ok2:
.mouse_done:
    mov al, PIC_EOI
    out PIC2_CMD, al

.eoi:
    mov al, PIC_EOI
    out PIC1_CMD, al
    pop rbx
    ret

; ============================================================
; BACKSPACE HELPER (kernel-specific; uses OSLIB2's cursor_pos)
; ============================================================

backspace:
    cmp dword [rel cursor_pos], 0
    je .done
    dec dword [rel cursor_pos]
    push rdi
    push rax
    mov eax, [rel cursor_pos]
    mov rdi, VGA_BUFFER
    add rdi, rax
    add rdi, rax
    mov byte [rdi], 0x20
    mov byte [rdi+1], VGA_ATTR
    pop rax
    pop rdi
.done:
    ret

; ============================================================
; IDT SETUP
; ============================================================

idt_setup:
    mov rdi, idt
    mov rcx, 512
    xor rax, rax
.clear:
    mov [rdi], rax
    add rdi, 8
    loop .clear

    mov rcx, 0
.isr_loop:
    cmp rcx, 32
    jge .irq_setup
    mov rsi, isr_stub_table
    mov rsi, [rsi + rcx * 8]
    mov rdi, rcx
    call idt_set_gate
    inc rcx
    jmp .isr_loop

.irq_setup:
    mov rcx, 0
.irq_loop:
    cmp rcx, 16
    jge .load
    mov rsi, irq_stub_table
    mov rsi, [rsi + rcx * 8]
    mov rdi, rcx
    add rdi, 32
    call idt_set_gate
    inc rcx
    jmp .irq_loop

.load:
    lidt [rel idt_descriptor]
    ret

idt_set_gate:
    push rbx
    mov rbx, rdi
    shl rbx, 4
    add rbx, idt
    mov [rbx + 0], si
    mov word [rbx + 2], 0x08           ; kernel code selector (OSLIB2 GDT)
    mov byte [rbx + 4], 0
    mov byte [rbx + 5], 0x8E           ; present, DPL=0, interrupt gate
    shr rsi, 16
    mov [rbx + 6], si
    shr rsi, 16
    mov [rbx + 8], esi
    mov dword [rbx + 12], 0
    pop rbx
    ret

; ============================================================
; PIC REMAPPING
; ============================================================

pic_remap:
    in al, PIC1_DATA
    mov bl, al
    in al, PIC2_DATA
    mov bh, al
    mov al, 0x11
    out PIC1_CMD, al
    out PIC2_CMD, al
    mov al, 32
    out PIC1_DATA, al
    mov al, 40
    out PIC2_DATA, al
    mov al, 4
    out PIC1_DATA, al
    mov al, 2
    out PIC2_DATA, al
    mov al, 0x01
    out PIC1_DATA, al
    out PIC2_DATA, al
    mov al, bl
    out PIC1_DATA, al
    mov al, bh
    out PIC2_DATA, al
    mov al, 0x00
    out PIC1_DATA, al
    out PIC2_DATA, al
    ret

; ============================================================
; PIT SETUP
; ============================================================

pit_setup:
    mov eax, PIT_FREQ
    xor edx, edx
    mov ebx, TARGET_FREQ
    div ebx
    mov ebx, eax
    mov al, 0x36
    out PIT_CMD, al
    mov al, bl
    out PIT_CHANNEL0, al
    mov al, bh
    out PIT_CHANNEL0, al
    ret

; ============================================================
; KEYBOARD SETUP
; ============================================================

keyboard_setup:
.flush:
    in al, KEYBOARD_STATUS
    test al, 1
    jz .done
    in al, KEYBOARD_DATA
    jmp .flush
.done:
    ret

; ============================================================
; MOUSE SETUP
; ============================================================

mouse_wait:
    push rcx
    mov rcx, 100000
.wait:
    in al, MOUSE_STATUS
    test rdi, rdi
    jz .want_write
    test al, 1
    jnz .ready
    jmp .next
.want_write:
    test al, 2
    jz .ready
.next:
    dec rcx
    jnz .wait
    pop rcx
    ret
.ready:
    pop rcx
    ret

mouse_write:
    push rax
    mov al, 0xD4
    out MOUSE_CMD, al
    xor rdi, rdi
    call mouse_wait
    mov al, sil
    out MOUSE_DATA, al
    pop rax
    ret

mouse_read:
    push rdi
    mov rdi, 1
    call mouse_wait
    pop rdi
    in al, MOUSE_DATA
    ret

mouse_setup:
    mov al, 0xA8
    out MOUSE_CMD, al
    mov al, 0x20
    out MOUSE_CMD, al
    call mouse_read
    or al, 2
    mov bl, al
    mov al, 0x60
    out MOUSE_CMD, al
    xor rdi, rdi
    call mouse_wait
    mov al, bl
    out MOUSE_DATA, al
    mov si, 0xF6
    call mouse_write
    call mouse_read
    mov si, 0xF4
    call mouse_write
    call mouse_read
    ret

; ============================================================
; STUB TABLES
; ============================================================

align 8
isr_stub_table:
    dq isr0,  isr1,  isr2,  isr3,  isr4,  isr5,  isr6,  isr7
    dq isr8,  isr9,  isr10, isr11, isr12, isr13, isr14, isr15
    dq isr16, isr17, isr18, isr19, isr20, isr21, isr22, isr23
    dq isr24, isr25, isr26, isr27, isr28, isr29, isr30, isr31

irq_stub_table:
    dq irq0,  irq1,  irq2,  irq3,  irq4,  irq5,  irq6,  irq7
    dq irq8,  irq9,  irq10, irq11, irq12, irq13, irq14, irq15

; ============================================================
; IDT DATA
; ============================================================

align 16
idt:
    times 256 * 16 db 0

idt_descriptor:
    dw 256 * 16 - 1
    dq idt

; ============================================================
; KEYBOARD TABLES
; ============================================================

keyboard_table:
    db 0, 0, '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=', 0, 0
    db 'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', '[', ']', 0, 0
    db 'a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', 0x27, '`', 0, 0x5C
    db 'z', 'x', 'c', 'v', 'b', 'n', 'm', ',', '.', '/', 0, 0, 0, 0, 0, 0
    times 32 db 0
    times 32 db 0

keyboard_table_shift:
    db 0, 0, '!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '_', '+', 0, 0
    db 'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', '{', '}', 0, 0
    db 'A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', ':', '"', '~', 0, '|'
    db 'Z', 'X', 'C', 'V', 'B', 'N', 'M', '<', '>', '?', 0, 0, 0, 0, 0, 0
    times 32 db 0
    times 32 db 0

; ============================================================
; STRINGS
; ============================================================

msg_hello               db "GUO OS kernel v0.6", 0
msg_stage               db " stage=", 0
msg_panic               db "PANIC: ", 0

msg_exception           db "EXCEPTION ", 0
msg_err                 db " err=", 0
msg_fault_addr          db "  fault addr: ", 0
msg_div_zero            db "  divide by zero", 0
msg_inv_opcode          db "  invalid opcode", 0
msg_gpf                 db "  general protection fault", 0
msg_page_fault          db "  page fault", 0
msg_halted              db "  system halted", 0

msg_ring3_enter         db "Entering ring 3...", 0
msg_ring3_ok            db "ring 3 init OK", 0
msg_user_prog           db "hello from ring 3", 10, 0
msg_user_prog_len       equ $ - msg_user_prog

; ============================================================
; KERNEL MAIN
; ============================================================

global kernel_main
kernel_main:
    call clear_screen

    mov rsi, msg_hello
    call print_line

    ; --- heap (from OSLIB2 v5) ---
    call heap_init

    ; --- ring 3 setup FIRST ---
    ; ring3_init reloads the GDT to OSLIB2 v5's GDT, where 0x08 is
    ; 64-bit kernel code. This must happen before idt_setup, so the
    ; IDT gates point at a valid 64-bit code segment in the new GDT.
    mov rsi, kernel_stack_top
    call ring3_init

    ; --- hardware init ---
    call idt_setup
    call pic_remap
    call pit_setup
    call keyboard_setup
    call mouse_setup

    mov rsi, msg_ring3_ok
    call print_line

    sti

    call shell_init

    ; ------------------------------------------------------------
    ; Ring 3 auto-entry disabled so the shell stays alive.
    ; Type 'run' in the shell to enter ring 3 with the demo program.
    ;
    ; call build_user_program
    ; mov rsi, msg_ring3_enter
    ; call print_line
    ; mov rsi, user_program_blob
    ; mov rdi, user_stack_top - 16
    ; call enter_user_mode
    ; ------------------------------------------------------------

.loop:
    hlt
    jmp .loop

; ============================================================
; BUILD USER PROGRAM
;
; Writes a tiny ring 3 program into user_program_blob.
; The program:
;   - sets up rdi/rsi/rdx for sys_write(1, msg, len)
;   - issues `syscall`
;   - sets rdi = 0 for sys_exit
;   - issues `syscall`
;   - loops forever (in case exit returns)
;
; This is machine code, assembled by hand. It's small enough
; that hand-encoding is fine.
; ============================================================

build_user_program:
    push rdi
    push rsi
    push rcx
    push rax

    mov rdi, user_program_blob

    ; ------------------------------------------------------------
    ; We can't easily embed a separate user .asm here, so we
    ; hand-assemble a minimal program. Bytes:
    ;
    ;   mov rdi, 1                48 C7 C7 01 00 00 00
    ;   mov rsi, <msg_addr>       48 BE <8 bytes>
    ;   mov rdx, <len>            48 BA <8 bytes>
    ;   mov rax, 1                48 C7 C0 01 00 00 00   (SYS_WRITE)
    ;   syscall                   0F 05
    ;   mov rdi, 0                48 C7 C7 00 00 00 00
    ;   mov rax, 0                48 C7 C0 00 00 00 00   (SYS_EXIT)
    ;   syscall                   0F 05
    ;   jmp $                     EB FE
    ;
    ; The message lives in the kernel's .data, so user code
    ; referencing it will read kernel memory. That works only
    ; because we haven't set up paging isolation yet. Once you
    ; add per-process page tables, copy the message into the
    ; user blob instead.
    ; ------------------------------------------------------------

    ; mov rdi, 1
    mov byte  [rdi + 0], 0x48
    mov byte  [rdi + 1], 0xC7
    mov byte  [rdi + 2], 0xC7
    mov dword [rdi + 3], 1
    add rdi, 7

    ; mov rsi, msg_user_prog
    mov byte  [rdi + 0], 0x48
    mov byte  [rdi + 1], 0xBE
    lea rax, [rel msg_user_prog]
    mov [rdi + 2], rax
    add rdi, 10

    ; mov rdx, msg_user_prog_len
    mov byte  [rdi + 0], 0x48
    mov byte  [rdi + 1], 0xBA
    mov rax, msg_user_prog_len
    mov [rdi + 2], rax
    add rdi, 10

    ; mov rax, SYS_WRITE (1)
    mov byte  [rdi + 0], 0x48
    mov byte  [rdi + 1], 0xC7
    mov byte  [rdi + 2], 0xC0
    mov dword [rdi + 3], 1
    add rdi, 7

    ; syscall
    mov byte  [rdi + 0], 0x0F
    mov byte  [rdi + 1], 0x05
    add rdi, 2

    ; mov rdi, 0
    mov byte  [rdi + 0], 0x48
    mov byte  [rdi + 1], 0xC7
    mov byte  [rdi + 2], 0xC7
    mov dword [rdi + 3], 0
    add rdi, 7

    ; mov rax, SYS_EXIT (0)
    mov byte  [rdi + 0], 0x48
    mov byte  [rdi + 1], 0xC7
    mov byte  [rdi + 2], 0xC0
    mov dword [rdi + 3], 0
    add rdi, 7

    ; syscall
    mov byte  [rdi + 0], 0x0F
    mov byte  [rdi + 1], 0x05
    add rdi, 2

    ; jmp $
    mov byte  [rdi + 0], 0xEB
    mov byte  [rdi + 1], 0xFE

    mov [rel user_program_entry], rdi

    pop rax
    pop rcx
    pop rsi
    pop rdi
    ret

; ============================================================
; SHELL MODULE (must be last so all symbols are defined)
; ============================================================

%include "Shell.asm"

; ============================================================
; OSLIB2 (last, so it can use symbols from everything above)
; ============================================================

%include "OSLIB2.asm"
