org 0x8000
bits 16

%define NULLDESC 0x0000
%define KMCODE   0x0008
%define KMDATA   0x0010
%define LONGCODE 0x0018
%define LONGDATA 0x0020

%define KERNEL_SRC  0x10000
%define KERNEL_DST  0x100000
%define KERNEL_SIZE 65536

load_gdt:
lgdt [gdt_descriptor]

mov eax, cr0
or eax, 0x1
mov cr0, eax

jmp KMCODE:protected_mode

bits 32
protected_mode:
mov ax, KMDATA
mov ds, ax
mov ss, ax
mov es, ax
mov fs, ax
mov gs, ax

mov esp, 0x90000

mov edi, 0xB8000
mov ecx, 80 * 25
mov ax, 0x0F20
.clear_pm:
mov [edi], ax
add edi, 2
loop .clear_pm

jmp check_for_long_mode

no_long_mode:
mov edi, 0xB8000
mov esi, msg_no_long_mode
mov ah, 0x0F
.print_nlm:
lodsb
test al, al
jz .halt_nlm
mov [edi], al
mov [edi+1], ah
add edi, 2
jmp .print_nlm
.halt_nlm:
hlt
jmp .halt_nlm

check_for_long_mode:
mov eax, 0x80000000
cpuid
cmp eax, 0x80000001
jb no_long_mode

mov eax, 0x80000001
cpuid
test edx, 1 << 29
jz no_long_mode

mov eax, pml4
mov cr3, eax

mov eax, cr4
or eax, 1 << 5
mov cr4, eax

mov ecx, 0xC0000080
rdmsr
or eax, 1 << 8
wrmsr

mov eax, cr0
or eax, 1 << 31
mov cr0, eax

push LONGCODE
push long_mode
retf

bits 64
long_mode:
mov ax, LONGDATA
mov ds, ax
mov ss, ax
mov es, ax
mov fs, ax
mov gs, ax

mov rsp, 0x90000

mov rsi, msg_loading
call print_line

mov rsi, KERNEL_SRC
mov rdi, KERNEL_DST
mov rcx, KERNEL_SIZE
.copy_loop:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    dec rcx
    jnz .copy_loop

mov rsi, msg_jumping
call print_line

jmp KERNEL_DST

; ============================================================
; BOOT-STAGE PRINT ROUTINES
; Local to boots2.asm. Cannot use OSLIB2 (ELF-only, uses
; section directives, [rel ...], and the func macro; also
; collides on gdt_start / gdt_end / gdt_descriptor).
; ============================================================

; ------------------------------------------------------------
; print_char -- writes a character to the VGA text buffer
; rsi = character (low byte used)
; ------------------------------------------------------------
print_char:
    push rdi
    push rax
    push rbx

    mov eax, [boot_cursor]
    mov rdi, 0xB8000
    add rdi, rax
    add rdi, rax

    mov [rdi], sil
    mov byte [rdi+1], 0x0F

    inc eax
    mov [boot_cursor], eax

    ; wrap at 80x25 = 2000 cells
    cmp eax, 2000
    jl .done
    mov dword [boot_cursor], 0
.done:
    pop rbx
    pop rax
    pop rdi
    ret

; ------------------------------------------------------------
; print_line -- writes a null-terminated string to VGA
; rsi = pointer to string
; ------------------------------------------------------------
print_line:
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
    ret

; ------------------------------------------------------------
; boot_cursor -- cursor position for boot-stage prints
; ------------------------------------------------------------
boot_cursor: dd 0

; ============================================================
; GDT
; ============================================================

gdt_start:

gdt_null:
dd 0x0
dd 0x0

gdt_code:
dw 0xFFFF
dw 0x0
db 0x0
db 10011010b
db 11001111b
db 0x0

gdt_data:
dw 0xFFFF
dw 0x0
db 0x0
db 10010010b
db 11001111b
db 0x0

gdt_long_code:
dw 0x0
dw 0x0
db 0x0
db 10011010b
db 10100000b
db 0x0

gdt_long_data:
dw 0x0
dw 0x0
db 0x0
db 10010010b
db 10100000b
db 0x0

gdt_end:

gdt_descriptor:
dw gdt_end - gdt_start - 1
dd gdt_start

align 4096
pml4:
    dq pdpt + 0x7
    times 511 dq 0

align 4096
pdpt:
    dq pd + 0x7
    times 511 dq 0

align 4096
pd:
    dq pt + 0x7
    times 511 dq 0

align 4096
pt:
    %assign i 0
    %rep 512
        dq (i * 0x1000) + 0x7
        %assign i i+1
    %endrep

msg_no_long_mode db "No long mode", 0
msg_loading db "Loading kernel...", 0
msg_jumping db "Jumping to kernel...", 0
