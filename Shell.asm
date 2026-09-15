; Shell.asm
; GUO OS shell v2
; Source-included from Kernel_S1.asm.
;
; v2:
;   - uses OSLIB2 v5 names (newline, tick_counter)
;   - fixed cmd_history loop (was using `loop` with wrong counter)
;   - removed dead shell_debug_2hex
;   - trimmed debug spam
;   - added: heap, run, sysinfo

bits 64

; ============================================================
; CONSTANTS
; ============================================================

%define SHELL_MAX_ARGS   8
%define SHELL_HISTORY    8
%define SHELL_LINE_MAX   256

; ============================================================
; SHELL STATE
; ============================================================

section .data

shell_running:      db 0
shell_argc:         dq 0
shell_args:         times SHELL_MAX_ARGS * 8 dq 0
shell_argv_buf:     times SHELL_LINE_MAX db 0

shell_history:      times SHELL_HISTORY * SHELL_LINE_MAX db 0
shell_history_count: dd 0

shell_cmd_buf:      times SHELL_LINE_MAX db 0

debug_prefix:       db "DBG: ", 0

section .text

; ============================================================
; DEBUG HELPER
; prints "DBG: <label>" and a hex value
; rsi = label, rdx = value
; ============================================================

shell_debug_hex:
    push rsi
    push rdx

    mov rsi, debug_prefix
    call print_string

    pop rdx
    mov rsi, rdx
    call print_hex
    call newline

    pop rsi
    ret

; ============================================================
; SHELL ENTRY POINTS
; ============================================================

shell_init:
    mov byte [rel shell_running], 1
    mov dword [rel shell_history_count], 0

    mov rsi, msg_shell_banner
    call print_line
    mov rsi, msg_shell_hint
    call print_line
    call newline
    call shell_prompt
    ret

shell_prompt:
    mov rsi, msg_shell_prompt
    call print_string
    ret

; ------------------------------------------------------------
; shell_handle_line - called when Enter is pressed
; ------------------------------------------------------------
shell_handle_line:
    push rbx
    push r12
    push r13

    ; copy line into shell_cmd_buf for safe keeping
    mov rsi, line_buffer
    mov rdi, shell_cmd_buf
    call strcpy

    ; if empty, just re-prompt
    cmp byte [rel shell_cmd_buf], 0
    je .done

    ; store in history
    call shell_add_history

    ; parse
    call shell_parse

    ; execute
    call shell_execute

.done:
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================
; PARSING
; ============================================================

shell_parse:
    push rbx
    push r12

    mov dword [rel shell_argc], 0

    mov rbx, shell_cmd_buf
    mov r12, shell_argv_buf

.skip_lead:
    mov al, [rbx]
    cmp al, ' '
    jne .first
    inc rbx
    jmp .skip_lead

.first:
    cmp byte [rbx], 0
    je .done

.token_loop:
    cmp dword [rel shell_argc], SHELL_MAX_ARGS
    jge .done

    mov rax, [rel shell_argc]
    mov [rel shell_args + rax * 8], r12
    inc dword [rel shell_argc]

.copy_token:
    mov al, [rbx]
    test al, al
    jz .end_token
    cmp al, ' '
    je .end_token
    mov [r12], al
    inc rbx
    inc r12
    jmp .copy_token

.end_token:
    mov byte [r12], 0
    inc r12

.skip_spaces:
    mov al, [rbx]
    cmp al, ' '
    jne .next_check
    inc rbx
    jmp .skip_spaces

.next_check:
    cmp byte [rbx], 0
    jne .token_loop

.done:
    pop r12
    pop rbx
    ret

; ============================================================
; EXECUTION
; ============================================================

shell_execute:
    push rbx

    mov rbx, cmd_table

.cmd_loop:
    mov rax, [rbx]
    test rax, rax
    jz .unknown

    ; compare args[0] with cmd name
    mov rsi, [rel shell_args]
    mov rdx, [rbx]
    push rbx
    call strcmp
    pop rbx

    test rax, rax
    jz .found

    add rbx, 16
    jmp .cmd_loop

.found:
    cli
    mov rax, [rbx + 8]
    call rax
    sti
    jmp .done

.unknown:
    mov rsi, msg_unknown_cmd
    call print_string
    mov rsi, [rel shell_args]
    call print_string
    call newline
    mov rsi, msg_try_help
    call print_line

.done:
    pop rbx
    ret

; ============================================================
; COMMAND TABLE
; ============================================================

section .data

cmd_table:
    dq cmd_help_name,    cmd_help
    dq cmd_clear_name,   cmd_clear
    dq cmd_echo_name,    cmd_echo
    dq cmd_ticks_name,   cmd_ticks
    dq cmd_mem_name,     cmd_mem
    dq cmd_uptime_name,  cmd_uptime
    dq cmd_rand_name,    cmd_rand
    dq cmd_color_name,   cmd_color
    dq cmd_about_name,   cmd_about
    dq cmd_version_name, cmd_version
    dq cmd_date_name,    cmd_date
    dq cmd_whoami_name,  cmd_whoami
    dq cmd_crash_name,   cmd_crashtest
    dq cmd_reboot_name,  cmd_reboot
    dq cmd_halt_name,    cmd_halt
    dq cmd_history_name, cmd_history
    dq cmd_hex_name,     cmd_hex
    dq cmd_dec_name,     cmd_dec
    dq cmd_hexdump_name, cmd_hexdump
    dq cmd_heap_name,    cmd_heap
    dq cmd_run_name,     cmd_run
    dq cmd_sysinfo_name, cmd_sysinfo
    dq cmd_panic_name,   cmd_panic
    dq 0, 0

cmd_help_name     db "help", 0
cmd_clear_name    db "clear", 0
cmd_echo_name     db "echo", 0
cmd_ticks_name    db "ticks", 0
cmd_mem_name      db "mem", 0
cmd_uptime_name   db "uptime", 0
cmd_rand_name     db "rand", 0
cmd_color_name    db "color", 0
cmd_about_name    db "about", 0
cmd_version_name  db "version", 0
cmd_date_name     db "date", 0
cmd_whoami_name   db "whoami", 0
cmd_crash_name    db "crashtest", 0
cmd_reboot_name   db "reboot", 0
cmd_halt_name     db "halt", 0
cmd_history_name  db "history", 0
cmd_hex_name      db "hex", 0
cmd_dec_name      db "dec", 0
cmd_hexdump_name  db "hexdump", 0
cmd_heap_name     db "heap", 0
cmd_run_name      db "run", 0
cmd_sysinfo_name  db "sysinfo", 0
cmd_panic_name    db "panic", 0

section .text

; ============================================================
; COMMAND IMPLEMENTATIONS
; ============================================================

cmd_help:
    mov rsi, msg_help
    call print_string
    ret

cmd_clear:
    call clear_screen
    ret

cmd_echo:
    mov eax, 1
.echo_loop:
    cmp eax, [rel shell_argc]
    jge .done

    ; print separator space before every arg except the first
    cmp eax, 1
    je .no_space
    mov rsi, ' '
    call print_char
.no_space:
    mov rsi, [rel shell_args + rax * 8]
    call print_string
    inc eax
    jmp .echo_loop
.done:
    call newline
    ret

cmd_ticks:
    mov rsi, msg_ticks
    call print_string
    mov rsi, [rel tick_counter]
    call print_dec
    call newline
    ret

cmd_uptime:
    mov rax, [rel tick_counter]
    xor edx, edx
    mov rcx, 100
    div rcx
    mov rsi, msg_uptime
    call print_string
    mov rsi, rax
    call print_dec
    mov rsi, msg_seconds
    call print_line
    ret

cmd_mem:
    mov rsi, msg_mem_cursor
    call print_string
    mov rsi, [rel cursor_pos]
    call print_dec
    call newline

    mov rsi, msg_mem_ticks
    call print_string
    mov rsi, [rel tick_counter]
    call print_dec
    call newline

    mov rsi, msg_mem_heap_ptr
    call print_string
    mov rsi, [rel heap_ptr]
    call print_hex
    call newline

    mov rsi, msg_mem_heap_head
    call print_string
    mov rsi, [rel heap_head]
    call print_hex
    call newline
    ret

cmd_heap:
    mov rsi, msg_heap_header
    call print_line
    call heap_dump
    ret

cmd_rand:
    mov rsi, msg_rand
    call print_string
    call rand
    mov rsi, rax
    call print_dec
    call newline
    ret

cmd_color:
    cmp dword [rel shell_argc], 2
    jl .usage
    mov rsi, [rel shell_args + 8]
    call atoi
    mov rsi, msg_color_set
    call print_string
    mov rsi, rax
    call print_dec
    call newline
    ret
.usage:
    mov rsi, msg_color_usage
    call print_line
    ret

cmd_about:
    mov rsi, msg_about
    call print_string
    ret

cmd_version:
    mov rsi, msg_version
    call print_line
    ret

cmd_date:
    mov rsi, msg_date
    call print_line
    ret

cmd_whoami:
    mov rsi, msg_whoami
    call print_line
    ret

cmd_crashtest:
    mov rsi, msg_crash
    call print_line
    xor rax, rax
    xor rdx, rdx
    div rdx
    ret

cmd_reboot:
    mov rsi, msg_reboot
    call print_line
    mov al, 0xFE
    out 0x64, al
    ret

cmd_halt:
    mov rsi, msg_halt
    call print_line
.h:
    hlt
    jmp .h

cmd_history:
    mov rsi, msg_history
    call print_string

    mov ecx, [rel shell_history_count]
    cmp ecx, SHELL_HISTORY
    jle .ok
    mov ecx, SHELL_HISTORY
.ok:
    test ecx, ecx
    jz .done

    xor r12, r12
.loop:
    ; r12 = index from 0 to ecx-1
    push rcx
    mov rax, r12
    imul rax, rax, SHELL_LINE_MAX
    mov rsi, shell_history
    add rsi, rax
    call print_string
    call newline
    pop rcx

    inc r12
    dec rcx
    jnz .loop
.done:
    ret

cmd_hex:
    cmp dword [rel shell_argc], 2
    jl .usage
    mov rsi, [rel shell_args + 8]
    call atoi
    mov rsi, rax
    call print_hex
    call newline
    ret
.usage:
    mov rsi, msg_hex_usage
    call print_line
    ret

cmd_dec:
    cmp dword [rel shell_argc], 2
    jl .usage
    mov rsi, [rel shell_args + 8]
    call atoi
    mov rsi, rax
    call print_dec
    call newline
    ret
.usage:
    mov rsi, msg_dec_usage
    call print_line
    ret

cmd_hexdump:
    cmp dword [rel shell_argc], 3
    jl .usage
    mov rsi, [rel shell_args + 8]
    call atoi
    mov rbx, rax
    mov rsi, [rel shell_args + 16]
    call atoi
    mov rdx, rax
    mov rsi, rbx
    call hexdump
    ret
.usage:
    mov rsi, msg_hexdump_usage
    call print_line
    ret

cmd_run:
    mov rsi, msg_run
    call print_line
    call build_user_program
    mov rsi, user_program_blob
    mov rdi, user_stack_top - 16
    call enter_user_mode
    ret

cmd_sysinfo:
    mov rsi, msg_sysinfo_title
    call print_line
    call newline

    mov rsi, msg_sysinfo_ver
    call print_string
    mov rsi, msg_version
    call print_line

    mov rsi, msg_sysinfo_ticks
    call print_string
    mov rsi, [rel tick_counter]
    call print_dec
    call newline

    mov rsi, msg_sysinfo_heap
    call print_string
    mov rsi, [rel heap_ptr]
    call print_hex
    call newline

    mov rsi, msg_sysinfo_pid
    call print_string
    mov rsi, [rel current_pid]
    call print_dec
    call newline

    mov rsi, msg_sysinfo_brk
    call print_string
    mov rsi, [rel user_brk]
    call print_hex
    call newline
    ret

cmd_panic:
    cmp dword [rel shell_argc], 2
    jl .usage
    mov rsi, [rel shell_args + 8]
    call panic
    ret
.usage:
    mov rsi, msg_panic_usage
    call print_line
    ret

; ============================================================
; HISTORY
; ============================================================

shell_add_history:
    push rbx
    push r12

    mov eax, [rel shell_history_count]
    cmp eax, SHELL_HISTORY
    jl .store

    ; shift all entries down by one
    mov r12, 1
.shift:
    cmp r12, SHELL_HISTORY
    jge .store

    ; rdi = history[r12]
    mov rax, r12
    imul rax, rax, SHELL_LINE_MAX
    mov rdi, shell_history
    add rdi, rax

    ; rsi = history[r12 - 1]
    mov rax, r12
    dec rax
    imul rax, rax, SHELL_LINE_MAX
    mov rsi, shell_history
    add rsi, rax

    push r12
    mov rdx, SHELL_LINE_MAX
    call memcpy
    pop r12

    inc r12
    jmp .shift

.store:
    mov eax, [rel shell_history_count]
    cmp eax, SHELL_HISTORY
    jl .ok
    mov eax, SHELL_HISTORY - 1
.ok:
    imul rax, rax, SHELL_LINE_MAX
    mov rdi, shell_history
    add rdi, rax
    mov rsi, shell_cmd_buf
    mov rdx, SHELL_LINE_MAX
    call memcpy

    mov eax, [rel shell_history_count]
    cmp eax, SHELL_HISTORY
    jge .done
    inc dword [rel shell_history_count]

.done:
    pop r12
    pop rbx
    ret

; ============================================================
; SHELL STRINGS
; ============================================================

section .data

msg_shell_banner    db "GUO OS Shell v2", 0
msg_shell_hint      db "type 'help' for a list of commands", 0
msg_shell_prompt    db "> ", 0

msg_unknown_cmd     db "unknown command: ", 0
msg_try_help        db "try 'help'", 0

msg_help            db "commands:", 10
                    db "  help              show this message", 10
                    db "  clear             clear the screen", 10
                    db "  echo <text>       print text", 10
                    db "  ticks             print timer ticks", 10
                    db "  uptime            print seconds since boot", 10
                    db "  mem               print memory/state info", 10
                    db "  heap              dump heap blocks", 10
                    db "  rand              print a random number", 10
                    db "  color <n>         set VGA color (stub)", 10
                    db "  hex <n>           print n in hex", 10
                    db "  dec <n>           print n in decimal", 10
                    db "  hexdump <a> <l>   dump memory", 10
                    db "  history           show command history", 10
                    db "  about             about GUO OS", 10
                    db "  version           print version", 10
                    db "  sysinfo           one-screen system overview", 10
                    db "  date              print date (stub)", 10
                    db "  whoami            print current user", 10
                    db "  run               enter ring 3 demo program", 10
                    db "  crashtest         trigger a divide by zero", 10
                    db "  panic <msg>       panic with message", 10
                    db "  reboot            reboot the machine", 10
                    db "  halt              halt the CPU", 10
                    db 0

msg_ticks           db "ticks: ", 0
msg_uptime          db "uptime: ", 0
msg_seconds         db " seconds", 0

msg_mem_cursor      db "cursor_pos: ", 0
msg_mem_ticks       db "tick_counter: ", 0
msg_mem_heap_ptr    db "heap_ptr: ", 0
msg_mem_heap_head   db "heap_head: ", 0

msg_heap_header     db "heap blocks (addr magic size next):", 0

msg_rand            db "rand: ", 0

msg_color_set       db "color set to: ", 0
msg_color_usage     db "usage: color <n>", 0

msg_about           db "GUO OS - a 64-bit hobby OS written in raw ASM.", 10
                    db "Built by one person, one interrupt handler at a time.", 10
                    db 0

msg_version         db "GUO OS v0.6 (shell v2)", 0
msg_date            db "date: not implemented yet", 0
msg_whoami          db "root", 0

msg_crash           db "triggering divide-by-zero...", 0
msg_reboot          db "rebooting...", 0
msg_halt            db "halted.", 0

msg_history         db "history:", 10, 0

msg_hex_usage       db "usage: hex <n>", 0
msg_dec_usage       db "usage: dec <n>", 0
msg_hexdump_usage   db "usage: hexdump <addr> <len>", 0
msg_panic_usage     db "usage: panic <msg>", 0

msg_run             db "entering ring 3...", 0

msg_sysinfo_title   db "=== GUO OS sysinfo ===", 0
msg_sysinfo_ver     db "version:  ", 0
msg_sysinfo_ticks   db "ticks:    ", 0
msg_sysinfo_heap    db "heap_ptr: ", 0
msg_sysinfo_pid     db "pid:      ", 0
msg_sysinfo_brk     db "brk:      ", 0
