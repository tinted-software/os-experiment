PHDRS
{
    text PT_LOAD;
}

SECTIONS
{
    . = 0x100000;

    .multiboot : ALIGN(8) {
        KEEP(*(.multiboot))
    } :text =0x90909090

    .boot : ALIGN(4K) {
        *(.boot)
    } :text

    .text : ALIGN(4K) {
        *(.text .text.*)
    } :text

    .rodata : ALIGN(4K) {
        *(.rodata .rodata.*)
    } :text

    .data : ALIGN(4K) {
        *(.data .data.*)
    } :text

    .bss : ALIGN(4K) {
        *(COMMON)
        *(.bss .bss.*)
    } :text
}
