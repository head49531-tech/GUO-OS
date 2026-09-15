org 0x7C00
bits 16

mov [boot_drive], dl

cli
xor ax, ax
mov ds, ax
mov es, ax
mov ss, ax
mov sp, 0x7C00

; --- load stage 2 (LBA 1, 64 sectors) to 0x8000 ---
mov si, dap_stage2
mov dl, [boot_drive]
mov ah, 0x42
int 0x13
jc err_stage2

; --- load kernel (LBA 65, 128 sectors) to 0x10000 ---
mov si, dap_kernel
mov dl, [boot_drive]
mov ah, 0x42
int 0x13
jc err_kernel

jmp 0x8000

err_stage2:
mov ah, 0x0E
mov al, 'S'
int 0x10
mov al, '2'
int 0x10
hlt
jmp err_stage2

err_kernel:
mov ah, 0x0E
mov al, 'K'
int 0x10
mov al, 'R'
int 0x10
hlt
jmp err_kernel

; --- Disk Address Packets ---
dap_stage2:
db 0x10
db 0
dw 64
dw 0x8000
dw 0x0000
dq 1

dap_kernel:
db 0x10
db 0
dw 128
dw 0x0000
dw 0x1000
dq 65

boot_drive db 0

times 510-($-$$) db 0
dw 0xAA55
