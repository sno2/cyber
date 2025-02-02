-- ./src/tools/cbindgen.cy -o src/tools/md4c.cy ~/repos/md4c/src/md4c.h -I/opt/homebrew/Cellar/llvm/17.0.5/include -libpath libmd4c.dylib -stripPrefix MD

var .libPath = switch os.system:
    case 'linux' => 'libmd4c.so'
    case 'windows' => 'md4c.dll'
    case 'macos' => 'libmd4c.dylib'
    else => throw error.Unsupported

-- CBINDGEN MARKER
-- Code below is generated by cbindgen.cy
type CHAR = int

type SIZE = int

type OFFSET = int

type BLOCKTYPE = int
var .BLOCK_DOC int = 0
var .BLOCK_QUOTE int = 1
var .BLOCK_UL int = 2
var .BLOCK_OL int = 3
var .BLOCK_LI int = 4
var .BLOCK_HR int = 5
var .BLOCK_H int = 6
var .BLOCK_CODE int = 7
var .BLOCK_HTML int = 8
var .BLOCK_P int = 9
var .BLOCK_TABLE int = 10
var .BLOCK_THEAD int = 11
var .BLOCK_TBODY int = 12
var .BLOCK_TR int = 13
var .BLOCK_TH int = 14
var .BLOCK_TD int = 15

type SPANTYPE = int
var .SPAN_EM int = 0
var .SPAN_STRONG int = 1
var .SPAN_A int = 2
var .SPAN_IMG int = 3
var .SPAN_CODE int = 4
var .SPAN_DEL int = 5
var .SPAN_LATEXMATH int = 6
var .SPAN_LATEXMATH_DISPLAY int = 7
var .SPAN_WIKILINK int = 8
var .SPAN_U int = 9

type TEXTTYPE = int
var .TEXT_NORMAL int = 0
var .TEXT_NULLCHAR int = 1
var .TEXT_BR int = 2
var .TEXT_SOFTBR int = 3
var .TEXT_ENTITY int = 4
var .TEXT_CODE int = 5
var .TEXT_HTML int = 6
var .TEXT_LATEXMATH int = 7

type ALIGN = int
var .ALIGN_DEFAULT int = 0
var .ALIGN_LEFT int = 1
var .ALIGN_CENTER int = 2
var .ALIGN_RIGHT int = 3

type ATTRIBUTE_S:
    text any -- const MD_CHAR *
    size SIZE
    substr_types any -- const MD_TEXTTYPE *
    substr_offsets any -- const MD_OFFSET *

type ATTRIBUTE = ATTRIBUTE_S

type BLOCK_UL_DETAIL_S:
    is_tight int
    mark CHAR

type BLOCK_UL_DETAIL = BLOCK_UL_DETAIL_S

type BLOCK_OL_DETAIL_S:
    start int
    is_tight int
    mark_delimiter CHAR

type BLOCK_OL_DETAIL = BLOCK_OL_DETAIL_S

type BLOCK_LI_DETAIL_S:
    is_task int
    task_mark CHAR
    task_mark_offset OFFSET

type BLOCK_LI_DETAIL = BLOCK_LI_DETAIL_S

type BLOCK_H_DETAIL_S:
    level int

type BLOCK_H_DETAIL = BLOCK_H_DETAIL_S

type BLOCK_CODE_DETAIL_S:
    info ATTRIBUTE
    lang ATTRIBUTE
    fence_char CHAR

type BLOCK_CODE_DETAIL = BLOCK_CODE_DETAIL_S

type BLOCK_TABLE_DETAIL_S:
    col_count int
    head_row_count int
    body_row_count int

type BLOCK_TABLE_DETAIL = BLOCK_TABLE_DETAIL_S

type BLOCK_TD_DETAIL_S:
    align ALIGN

type BLOCK_TD_DETAIL = BLOCK_TD_DETAIL_S

type SPAN_A_DETAIL_S:
    href ATTRIBUTE
    title ATTRIBUTE

type SPAN_A_DETAIL = SPAN_A_DETAIL_S

type SPAN_IMG_DETAIL_S:
    src ATTRIBUTE
    title ATTRIBUTE

type SPAN_IMG_DETAIL = SPAN_IMG_DETAIL_S

type SPAN_WIKILINK_S:
    target ATTRIBUTE

type SPAN_WIKILINK_DETAIL = SPAN_WIKILINK_S

type PARSER_S:
    abi_version int
    flags int
    enter_block any -- int (*)(MD_BLOCKTYPE, void *, void *)
    leave_block any -- int (*)(MD_BLOCKTYPE, void *, void *)
    enter_span any -- int (*)(MD_SPANTYPE, void *, void *)
    leave_span any -- int (*)(MD_SPANTYPE, void *, void *)
    text any -- int (*)(MD_TEXTTYPE, const MD_CHAR *, MD_SIZE, void *)
    debug_log any -- void (*)(const char *, void *)
    syntax any -- void (*)(void)

type PARSER = PARSER_S

type RENDERER = PARSER

func md_parse(text any, size SIZE, parser any, userdata any) int: pass

import os
my .ffi = false
my .lib = load()
func load():
    ffi = os.newFFI()
    ffi.cbind(ATTRIBUTE_S, [.voidPtr, .uint, .voidPtr, .voidPtr])
    ffi.cbind(BLOCK_UL_DETAIL_S, [.int, .char])
    ffi.cbind(BLOCK_OL_DETAIL_S, [.uint, .int, .char])
    ffi.cbind(BLOCK_LI_DETAIL_S, [.int, .char, .uint])
    ffi.cbind(BLOCK_H_DETAIL_S, [.uint])
    ffi.cbind(BLOCK_CODE_DETAIL_S, [ATTRIBUTE, ATTRIBUTE, .char])
    ffi.cbind(BLOCK_TABLE_DETAIL_S, [.uint, .uint, .uint])
    ffi.cbind(BLOCK_TD_DETAIL_S, [.int])
    ffi.cbind(SPAN_A_DETAIL_S, [ATTRIBUTE, ATTRIBUTE])
    ffi.cbind(SPAN_IMG_DETAIL_S, [ATTRIBUTE, ATTRIBUTE])
    ffi.cbind(SPAN_WIKILINK_S, [ATTRIBUTE])
    ffi.cbind(PARSER_S, [.uint, .uint, .voidPtr, .voidPtr, .voidPtr, .voidPtr, .voidPtr, .voidPtr, .voidPtr])
    ffi.cfunc('md_parse', [.voidPtr, .uint, .voidPtr, .voidPtr], .int)
    my lib = ffi.bindLib([?String some: libPath], [genMap: true])
    md_parse = lib.md_parse
    return lib

-- Macros
var .GCC_HAVE_DWARF2_CFI_ASM int = 1
var .FLAG_COLLAPSEWHITESPACE int = 1
var .FLAG_PERMISSIVEATXHEADERS int = 2
var .FLAG_PERMISSIVEURLAUTOLINKS int = 4
var .FLAG_PERMISSIVEEMAILAUTOLINKS int = 8
var .FLAG_NOINDENTEDCODEBLOCKS int = 16
var .FLAG_NOHTMLBLOCKS int = 32
var .FLAG_NOHTMLSPANS int = 64
var .FLAG_TABLES int = 256
var .FLAG_STRIKETHROUGH int = 512
var .FLAG_PERMISSIVEWWWAUTOLINKS int = 1024
var .FLAG_TASKLISTS int = 2048
var .FLAG_LATEXMATHSPANS int = 4096
var .FLAG_WIKILINKS int = 8192
var .FLAG_UNDERLINE int = 16384
var .FLAG_PERMISSIVEAUTOLINKS int = 1036
var .FLAG_NOHTML int = 96
var .DIALECT_COMMONMARK int = 0
var .DIALECT_GITHUB int = 3852
