package sdl3_ttf

import "core:c"
import sdl "vendor:sdl3"

Uint32 :: sdl.Uint32
Uint8 :: sdl.Uint8
Rect :: sdl.Rect
FPoint :: sdl.FPoint
Color :: sdl.Color
GPUTexture :: sdl.GPUTexture
GPUDevice :: sdl.GPUDevice
IOStream :: sdl.IOStream
PropertiesID :: sdl.PropertiesID
Surface :: sdl.Surface
Renderer :: sdl.Renderer

// CONSTANTS
// ----------
PROP_FONT_CREATE_FILENAME_STRING :: "SDL_ttf.font.create.filename"
PROP_FONT_CREATE_IOSTREAM_POINTER :: "SDL_ttf.font.create.iostream"
PROP_FONT_CREATE_IOSTREAM_OFFSET_NUMBER :: "SDL_ttf.font.create.iostream.offset"
PROP_FONT_CREATE_IOSTREAM_AUTOCLOSE_BOOLEAN :: "SDL_ttf.font.create.iostream.autoclose"
PROP_FONT_CREATE_SIZE_FLOAT :: "SDL_ttf.font.create.size"
PROP_FONT_CREATE_FACE_NUMBER :: "SDL_ttf.font.create.face"
PROP_FONT_CREATE_HORIZONTAL_DPI_NUMBER :: "SDL_ttf.font.create.hdpi"
PROP_FONT_CREATE_VERTICAL_DPI_NUMBER :: "SDL_ttf.font.create.vdpi"
PROP_FONT_CREATE_EXISTING_FONT :: "SDL_ttf.font.create.existing_font"

PROP_FONT_OUTLINE_LINE_CAP_NUMBER :: "SDL_ttf.font.outline.line_cap"
PROP_FONT_OUTLINE_LINE_JOIN_NUMBER :: "SDL_ttf.font.outline.line_join"
PROP_FONT_OUTLINE_MITER_LIMIT_NUMBER :: "SDL_ttf.font.outline.miter_limit"

PROP_RENDERER_TEXT_ENGINE_RENDERER :: "SDL_ttf.renderer_text_engine.create.renderer"
PROP_RENDERER_TEXT_ENGINE_ATLAS_TEXTURE_SIZE :: "SDL_ttf.renderer_text_engine.create.atlas_texture_size"

PROP_GPU_TEXT_ENGINE_DEVICE :: "SDL_ttf.gpu_text_engine.create.device"
PROP_GPU_TEXT_ENGINE_ATLAS_TEXTURE_SIZE :: "SDL_ttf.gpu_text_engine.create.atlas_texture_size"


// STRUCTS
// ----------
Font :: struct {
} //Opaque data
// TextEngine :: struct {}
// TextData :: struct {}

Text :: struct {
	text:      cstring, /**< A copy of the UTF-8 string that this text object represents, useful for layout, debugging and retrieving substring text. This is updated when the text object is modified and will be freed automatically when the object is destroyed. */
	num_lines: c.int, /**< The number of lines in the text, 0 if it's empty */
	refcount:  c.int, /**< Application reference count, used when freeing surface */
	internal:  ^TextData, /**< Private */
}

GPUAtlasDrawSequence :: struct {
	atlas_texture: ^GPUTexture, /**< Texture atlas that stores the glyphs */
	xy:            [^]FPoint, /**< An array of vertex positions */
	uv:            [^]FPoint, /**< An array of normalized texture coordinates for each vertex */
	num_vertices:  c.int, /**< Number of vertices */
	indices:       [^]c.int, /**< An array of indices into the 'vertices' arrays */
	num_indices:   c.int, /**< Number of indices */
	image_type:    ImageType, /**< The image type of this draw sequence */
	next:          ^GPUAtlasDrawSequence, /**< The next sequence (will be NULL in case of the last sequence) */
}

SubString :: struct {
	flags:         SubStringFlags, /**< The flags for this substring */
	offset:        c.int, /**< The byte offset from the beginning of the text */
	length:        c.int, /**< The byte length starting at the offset */
	line_index:    c.int, /**< The index of the line that contains this substring */
	cluster_index: c.int, /**< The internal cluster index, used for quickly iterating */
	rect:          Rect, /**< The rectangle, relative to the top left of the text, containing the substring */
}

// ENUMS
// ----------
FontStyleFlags :: distinct bit_set[FontStyleFlag;Uint32]
FontStyleFlag :: enum Uint32 {
	NORMAL        = 0, /**< No special style */
	BOLD          = 1, /**< Bold style */
	ITALIC        = 2, /**< Italic style */
	UNDERLINE     = 3, /**< Underlined text */
	STRIKETHROUGH = 4, /**< Strikethrough text */
}

HintingFlags :: enum c.int {
	NORMAL = 0, /**< Normal hinting applies standard grid-fitting. */
	LIGHT, /**< Light hinting applies subtle adjustments to improve rendering. */
	MONO, /**< Monochrome hinting adjusts the font for better rendering at lower resolutions. */
	NONE, /**< No hinting, the font is rendered without any grid-fitting. */
	LIGHT_SUBPIXEL, /**< Light hinting with subpixel rendering for more precise font edges. */
}

HorizontalAlignment :: enum c.int {
	INVALID = -1,
	LEFT,
	CENTER,
	RIGHT,
}

Direction :: enum c.int {
	INVALID = 0,
	LTR = 4, /**< Left to Right */
	RTL, /**< Right to Left */
	TTB, /**< Top to Bottom */
	BTT, /**< Bottom to Top */
}

ImageType :: enum c.int {
	INVALID,
	ALPHA, /**< The color channels are white */
	COLOR, /**< The color channels have image data */
	SDF, /**< The alpha channel has signed distance field information */
}

GPUTextEngineWinding :: enum c.int {
	INVALID = -1,
	CLOCKWISE,
	COUNTER_CLOCKWISE,
}

SubStringFlags :: distinct bit_set[SubStringFlag;Uint32]
SubStringFlag :: enum Uint32 {
	// 0x000000FF,   
	// 0x00000100,  
	// 0x00000200, 
	// 0x00000400,  
	// 0x00000800,  
	// TODO(devon): I feel like these are wrong as hell
	DIRECTION_MASK = 0 << 0xFF, /**< The mask for the flow direction for this substring */
	TEXT_START     = 1, /**< This substring contains the beginning of the text */
	LINE_START     = 2, /**< This substring contains the beginning of line `line_index` */
	LINE_END       = 4, /**< This substring contains the end of line `line_index` */
	TEXT_END       = 8, /**< This substring contains the end of the text */
}


// PROCEDURES
// ----------
@(default_calling_convention = "c", link_prefix = "TTF_")
foreign lib {
	Version :: proc() -> c.int ---
	GetFreeTypeVersion :: proc(major: ^c.int, minor: ^c.int, patch: ^c.int) ---
	GetHarfBuzzVersion :: proc(major: ^c.int, minor: ^c.int, patch: ^c.int) ---

	Init :: proc() -> bool ---
	OpenFont :: proc(file: cstring, ptsize: c.float) -> ^Font ---
	OpenFontIO :: proc(src: ^IOStream, closeio: bool, ptsize: c.float) -> ^Font ---
	OpenFontWithProperties :: proc(props: PropertiesID) -> ^Font ---

	CopyFont :: proc(existing_font: ^Font) -> ^Font ---
	GetFontProperties :: proc(font: ^Font) -> PropertiesID ---

	GetFontGeneration :: proc(font: ^Font) -> Uint32 ---
	AddFallbackFont :: proc(font: ^Font, fallback: ^Font) -> bool ---
	RemoveFallbackFont :: proc(font: ^Font, fallback: ^Font) ---
	ClearFallbackFonts :: proc(font: ^Font) ---
	SetFontSize :: proc(font: ^Font, ptsize: c.float) -> bool ---
	SetFontSizeDPI :: proc(font: ^Font, ptsize: c.float, hdpi: c.int, vdpi: c.int) -> bool ---
	GetFontSize :: proc(font: ^Font) -> c.float ---
	GetFontDPI :: proc(font: ^Font, hdpi: ^c.int, vdpi: ^c.int) -> bool ---

	SetFontStyle :: proc(#by_ptr font: Font, style: FontStyleFlags) ---
	GetFontStyle :: proc(#by_ptr font: Font) -> FontStyleFlags ---
	SetFontOutline :: proc(font: ^Font, outline: c.int) -> bool ---
	GetFontOutline :: proc(#by_ptr font: Font) -> c.int ---

	SetFontHinting :: proc(font: ^Font, hinting: HintingFlags) ---
	GetNumFontFaces :: proc(#by_ptr font: Font) -> c.int ---
	GetFontHinting :: proc(#by_ptr font: Font) -> HintingFlags ---
	SetFontSDF :: proc(font: ^Font, enabled: bool) -> bool ---
	GetFontSDF :: proc(#by_ptr font: Font) -> bool ---

	SetFontWrapAlignment :: proc(font: ^Font, align: HorizontalAlignment) ---
	GetFontWrapAlignment :: proc(#by_ptr font: Font) -> HorizontalAlignment ---
	GetFontHeight :: proc(#by_ptr font: Font) -> c.int ---
	GetFontAscent :: proc(#by_ptr font: Font) -> c.int ---
	GetFontDescent :: proc(#by_ptr font: Font) -> c.int ---
	SetFontLineSkip :: proc(font: ^Font, lineskip: c.int) ---
	GetFontLineSkip :: proc(#by_ptr font: Font) -> c.int ---
	SetFontKerning :: proc(font: ^Font, enabled: bool) ---
	GetFontKerning :: proc(#by_ptr font: Font) -> bool ---
	IsFixedWidth :: proc(#by_ptr font: Font) -> bool ---
	IsScalable :: proc(#by_ptr font: Font) -> bool ---
	GetFontFamilyName :: proc(#by_ptr font: Font) -> cstring ---
	GetFontStyleName :: proc(#by_ptr font: Font) -> cstring ---

	SetFontDirection :: proc(font: ^Font, direction: Direction) -> bool ---
	GetFontDirection :: proc(#by_ptr font: Font) -> Direction ---
	StringToTag :: proc(str: cstring) -> Uint32 ---
	TagToString :: proc(tag: Uint32, str: cstring, size: c.size_t) ---
	SetFontScript :: proc(font: ^Font, script: Uint32) -> bool ---
	GetFontScript :: proc(#by_ptr font: Font) -> Uint32 ---
	GetGlyphScript :: proc(ch: Uint32) -> Uint32 ---
	SetFontLanguage :: proc(font: ^Font, language_bcp47: cstring) -> bool ---
	HasGlyph :: proc(#by_ptr font: Font, ch: Uint32) -> bool ---
	GetGlyphImage :: proc(font: ^Font, ch: Uint32, image_type: ^ImageType) -> ^Surface ---
	GetGlyphImageForIndex :: proc(font: ^Font, glyph_index: Uint32, image_type: ^ImageType) -> ^Surface ---
	GetGlyphMetrics :: proc(font: ^Font, ch: Uint32, minx: ^c.int, maxx: ^c.int, miny: ^c.int, maxy: ^c.int, advance: ^c.int) -> bool ---
	GetGlyphKerning :: proc(font: ^Font, previous_ch: Uint32, ch: Uint32, kerning: ^c.int) -> bool ---
	GetStringSize :: proc(font: ^Font, text: cstring, length: c.size_t, w: ^c.int, h: ^c.int) -> bool ---
	GetStringSizeWrapped :: proc(font: ^Font, text: cstring, length: c.size_t, wrap_width: c.int, w: ^c.int, h: ^c.int) -> bool ---
	MeasureString :: proc(font: ^Font, text: cstring, length: c.size_t, max_width: c.int, measured_width: ^c.int, measured_length: ^c.size_t) -> bool ---
	RenderText_Solid :: proc(font: ^Font, text: cstring, length: c.size_t, fg: Color) -> ^Surface ---
	RenderText_Solid_Wrapped :: proc(font: ^Font, text: cstring, length: c.size_t, fg: Color, wrap_length: c.int) -> ^Surface ---
	RenderGlyph_Solid :: proc(font: ^Font, ch: Uint32, fg: Color) -> ^Surface ---
	RenderText_Shaded :: proc(font: ^Font, text: cstring, length: c.size_t, fg: Color, bg: Color) -> ^Surface ---
	RenderText_Shaded_Wrapped :: proc(font: ^Font, text: cstring, length: c.size_t, fg: Color, bg: Color, wrap_width: c.int) -> ^Surface ---
	RenderGlyph_Shaded :: proc(font: ^Font, ch: Uint32, fg: Color, bg: Color) -> ^Surface ---
	RenderText_Blended :: proc(font: ^Font, text: cstring, length: c.size_t, fg: Color) -> ^Surface ---
	RenderText_Blended_Wrapped :: proc(font: ^Font, text: cstring, length: c.size_t, fg: Color, wrap_width: c.int) -> ^Surface ---
	RenderGlyph_Blended :: proc(font: ^Font, ch: Uint32, fg: Color) -> ^Surface ---
	RenderText_LCD :: proc(font: ^Font, text: cstring, length: c.size_t, fg: Color, bg: Color) -> ^Surface ---
	RenderText_LCD_Wrapped :: proc(font: ^Font, text: cstring, length: c.size_t, fg: Color, bg: Color, wrap_width: c.int) -> ^Surface ---
	RenderGlyph_LCD :: proc(font: ^Font, ch: Uint32, fg: Color, bg: Color) -> ^Surface ---

	CreateSurfaceTextEngine :: proc() -> ^TextEngine ---
	DrawSurfaceText :: proc(text: ^Text, x: c.int, y: c.int, surface: ^Surface) -> bool ---
	DestroySurfaceTextEngine :: proc(engine: ^TextEngine) ---

	CreateRendererTextEngine :: proc(renderer: ^Renderer) -> ^TextEngine ---
	CreateRendererTextEngineWithProperties :: proc(props: PropertiesID) -> ^TextEngine ---
	DrawRendererText :: proc(text: ^Text, x: c.float, y: c.float) -> bool ---
	DestroyRendererTextEngine :: proc(engine: ^TextEngine) ---

	CreateGPUTextEngine :: proc(device: ^GPUDevice) -> ^TextEngine ---
	CreateGPUTextEngineWithProperties :: proc(props: PropertiesID) -> ^TextEngine ---
	GetGPUTextDrawData :: proc(text: ^Text) -> ^GPUAtlasDrawSequence ---
	DestroyGPUTextEngine :: proc(engine: ^TextEngine) ---
	SetGPUTextEngineWinding :: proc(engine: ^TextEngine, winding: GPUTextEngineWinding) ---
	GetGPUTextEngineWinding :: proc(#by_ptr engine: TextEngine) -> GPUTextEngineWinding ---

	CreateText :: proc(engine: ^TextEngine, font: ^Font, text: cstring, length: c.size_t) -> ^Text ---
	GetTextProperties :: proc(text: ^Text) -> PropertiesID ---
	SetTextEngine :: proc(text: ^Text, engine: ^TextEngine) -> bool ---
	GetTextEngine :: proc(text: ^Text) -> ^TextEngine ---
	SetTextFont :: proc(text: ^Text, font: ^Font) -> bool ---
	GetTextFont :: proc(text: ^Text) -> ^Font ---
	SetTextDirection :: proc(text: ^Text, direction: Direction) -> bool ---
	GetTextDirection :: proc(textu: ^Text) -> Direction ---
	SetTextScript :: proc(text: ^Text, script: Uint32) -> bool ---
	GetTextScript :: proc(text: ^Text) -> Uint32 ---
	SetTextColor :: proc(text: ^Text, r: Uint8, g: Uint8, b: Uint8, a: Uint8) -> bool ---
	SetTextColorFloat :: proc(text: ^Text, r: c.float, g: c.float, b: c.float, a: c.float) -> bool ---
	GetTextColor :: proc(text: ^Text, r: ^Uint8, g: ^Uint8, b: ^Uint8, a: ^Uint8) -> bool ---
	GetTextColorFloat :: proc(text: ^Text, r: ^c.float, g: ^c.float, b: ^c.float, a: ^c.float) -> bool ---
	SetTextPosition :: proc(text: ^Text, x: c.int, y: c.int) -> bool ---
	GetTextPosition :: proc(text: ^Text, x: ^c.int, y: ^c.int) -> bool ---
	SetTextWrapWidth :: proc(text: ^Text, wrap_width: c.int) -> bool ---
	GetTextWrapWidth :: proc(text: ^Text, wrap_width: ^c.int) -> bool ---
	SetTextWrapWhitespaceVisible :: proc(text: ^Text, visible: bool) -> bool ---
	TextWrapWhitespaceVisible :: proc(text: ^Text) -> bool ---
	SetTextString :: proc(text: ^Text, str: cstring, length: c.size_t) -> bool ---
	InsertTextString :: proc(text: ^Text, offset: c.int, str: cstring, length: c.size_t) -> bool ---
	AppendTextString :: proc(text: ^Text, str: cstring, length: c.size_t) -> bool ---
	DeleteTextString :: proc(text: ^Text, offset: c.int, length: c.int) -> bool ---
	GetTextSize :: proc(text: ^Text, w: ^c.int, h: ^c.int) -> bool ---
	GetTextSubString :: proc(text: ^Text, offset: c.int, substring: ^SubString) -> bool ---
	GetTextSubStringForLine :: proc(text: ^Text, line: c.int, substring: ^SubString) -> bool ---
	GetTextSubStringsForRange :: proc(text: ^Text, offset: c.int, length: c.int, count: ^c.int) -> [^]^SubString ---
	GetTextSubStringForPoint :: proc(text: ^Text, x: c.int, y: c.int, substring: ^SubString) -> bool ---
	GetPreviousTextSubString :: proc(text: ^Text, #by_ptr substring: SubString, prvious: ^SubString) -> bool ---
	GetNextTextSubString :: proc(text: ^Text, #by_ptr substring: SubString, next: ^SubString) -> bool ---
	UpdateText :: proc(text: ^Text) -> bool ---
	DestroyText :: proc(text: ^Text) ---

	CloseFont :: proc(font: ^Font) ---
	Quit :: proc() ---
	WasInit :: proc() -> c.int ---

}
