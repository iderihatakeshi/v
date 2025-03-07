// Copyright (c) 2019 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.

module main

import (
	os
	strings
	benchmark
)

const (
	Version = '0.1.20'
)

enum BuildMode {
	// `v program.v'
	// Build user code only, and add pre-compiled vlib (`cc program.o builtin.o os.o...`)
	default_mode
	// `v -embed_vlib program.v`
	// vlib + user code in one file (slower compilation, but easier when working on vlib and cross-compiling)
	embed_vlib
	// `v -lib ~/v/os`
	// build any module (generate os.o + os.vh)
	build_module
}

const (
	SupportedPlatforms = ['windows', 'mac', 'linux', 'freebsd', 'openbsd',
		'netbsd', 'dragonfly', 'msvc', 'android', 'js']
	ModPath            = os.home_dir() + '/.vmodules/'
)

enum OS {
	mac
	linux
	windows
	freebsd
	openbsd
	netbsd
	dragonfly
	msvc
	js
}

enum Pass {
	// A very short pass that only looks at imports in the beginning of
	// each file
	imports
	// First pass, only parses and saves declarations (fn signatures,
	// consts, types).
	// Skips function bodies.
	// We need this because in V things can be used before they are
	// declared.
	decl
	// Second pass, parses function bodies and generates C or machine code.
	main
}

struct V {
mut:
	os         OS // the OS to build for
	out_name_c string // name of the temporary C file
	files      []string // all V files that need to be parsed and compiled
	dir        string // directory (or file) being compiled (TODO rename to path?)
	table      &Table // table with types, vars, functions etc
	cgen       &CGen // C code generator
	pref       &Preferences // all the preferences and settings extracted to a struct for reusability
	lang_dir   string // "~/code/v"
	out_name   string // "program.exe"
	vroot      string
	mod        string  // module being built with -lib
	parsers    []Parser
}

struct Preferences {
mut:
	build_mode     BuildMode
	nofmt          bool // disable vfmt
	is_test        bool // `v test string_test.v`
	is_script      bool // single file mode (`v program.v`), main function can be skipped
	is_live        bool // for hot code reloading
	is_so          bool
	is_prof        bool // benchmark every function
	translated     bool // `v translate doom.v` are we running V code translated from C? allow globals, ++ expressions, etc
	is_prod        bool // use "-O2"
	is_verbose     bool // print extra information with `v.log()`
	obfuscate      bool // `v -obf program.v`, renames functions to "f_XXX"
	is_repl        bool
	is_run         bool
	show_c_cmd     bool // `v -show_c_cmd` prints the C command to build program.v.c
	sanitize       bool // use Clang's new "-fsanitize" option
	is_debuggable  bool
	is_debug       bool // keep compiled C files
	no_auto_free   bool // `v -nofree` disable automatic `free()` insertion for better performance in some applications  (e.g. compilers)
	cflags        string // Additional options which will be passed to the C compiler.
						 // For example, passing -cflags -Os will cause the C compiler to optimize the generated binaries for size.
						 // You could pass several -cflags XXX arguments. They will be merged with each other.
						 // You can also quote several options at the same time: -cflags '-Os -fno-inline-small-functions'.
	ccompiler  string // the name of the used C compiler
	building_v bool
	autofree   bool
	compress   bool
}

fn main() {
	// There's no `flags` module yet, so args have to be parsed manually
	args := env_vflags_and_os_args()
	// Print the version and exit.
	if '-v' in args || '--version' in args || 'version' in args {
		version_hash := vhash()
		println('V $Version $version_hash')
		return
	}
	if '-h' in args || '--help' in args || 'help' in args {
		println(HelpText)
		return
	}
	if 'translate' in args {
		println('Translating C to V will be available in V 0.3')
		return
	}
	if 'up' in args {
		update_v()
		return
	}
	if 'get' in args {
		println('use `v install` to install modules from vpm.vlang.io ')
		return
	}
	if 'symlink' in args {
		create_symlink()
		return
	}
	if 'install' in args {
		install_v(args)
		return
	}
	// TODO quit if the compiler is too old
	// u := os.file_last_mod_unix('v')
	// If there's no tmp path with current version yet, the user must be using a pre-built package
	// Copy the `vlib` directory to the tmp path.
/*
	// TODO
	if !os.file_exists(TmpPath) && os.file_exists('vlib') {
	}
*/
	// Just fmt and exit
	if 'fmt' in args {
		vfmt(args)
		return
	}
	// Construct the V object from command line arguments
	mut v := new_v(args)
	if args.join(' ').contains(' test v') {
		v.test_v()
		return
	}
	if v.pref.is_verbose {
		println(args)
	}
	// Generate the docs and exit
	if 'doc' in args {
		// v.gen_doc_html_for_module(args.last())
		exit(0)
	}

	if 'run' in args {
		// always recompile for now, too error prone to skip recompilation otherwise
		// for example for -repl usage, especially when piping lines to v
		v.compile()
		v.run_compiled_executable_and_exit()
	}

	// No args? REPL
	if args.len < 2 || (args.len == 2 && args[1] == '-') || 'runrepl' in args {
		run_repl()
		return
	}

	v.compile()

	if v.pref.is_test {
		v.run_compiled_executable_and_exit()
	}
	
	// TODO remove
	if v.pref.autofree {
		println('started freeing v struct')
		v.table.typesmap.free()
		v.table.obf_ids.free()
		v.cgen.lines.free()
		free(v.cgen)
		for _, f in v.table.fns {
			f.local_vars.free()
			f.args.free()
			//f.defer_text.free()
		}	
		v.table.fns.free()
		free(v.table)
		//for p in parsers {
			
		//}	
		println('done!')
	}	
}

fn (v mut V) add_parser(parser Parser) {
       for p in v.parsers {
               if p.file_path == parser.file_path {
                       return
               }
       }
       v.parsers << parser
}


fn (v mut V) compile() {
	// Emily: Stop people on linux from being able to build with msvc
	if os.user_os() != 'windows' && v.os == .msvc {
		cerror('Cannot build with msvc on ${os.user_os()}')
	}

	mut cgen := v.cgen
	cgen.genln('// Generated by V')
	// Add builtin parsers
	for i, file in v.files {
	//        v.parsers << v.new_parser(file)
	}
	if v.pref.is_verbose {
		println('all .v files before:')
		println(v.files)
	}
	v.add_v_files_to_compile()
	if v.pref.is_verbose || v.pref.is_debug {
		println('all .v files:')
		println(v.files)
	}
	// First pass (declarations)
	for file in v.files {
		mut p := v.new_parser(file)
		p.parse(.decl)
		
		
	}
	// Main pass
	cgen.pass = Pass.main
	if v.pref.is_debug {
		$if js {
			cgen.genln('const VDEBUG = 1;\n')
		}	$else {
			cgen.genln('#define VDEBUG (1)')
		}
	}
	if v.os == .js {
		cgen.genln('#define _VJS (1) ')
	}

	if v.pref.building_v {
		cgen.genln('#ifndef V_COMMIT_HASH')
		cgen.genln('#define V_COMMIT_HASH "' + vhash() + '"')
		cgen.genln('#endif')
	}
		
	$if js {
		cgen.genln(js_headers)
	} $else {
		cgen.genln(CommonCHeaders)
	}
	
	v.generate_hotcode_reloading_declarations()

	imports_json := 'json' in v.table.imports
	// TODO remove global UI hack
	if v.os == .mac && ((v.pref.build_mode == .embed_vlib && 'ui' in
		v.table.imports) || (v.pref.build_mode == .build_module &&
		v.dir.contains('/ui'))) {
		cgen.genln('id defaultFont = 0; // main.v')
	}
	// We need the cjson header for all the json decoding user will do in default mode
	if v.pref.build_mode == .default_mode {
		if imports_json {
			cgen.genln('#include "cJSON.h"')
		}
	}
	if v.pref.build_mode == .embed_vlib || v.pref.build_mode == .default_mode {
		// If we declare these for all modes, then when running `v a.v` we'll get
		// `/usr/bin/ld: multiple definition of 'total_m'`
		// TODO
		//cgen.genln('i64 total_m = 0; // For counting total RAM allocated')
		//if v.pref.is_test {
		$if !js {
			cgen.genln('int g_test_ok = 1; ')
		}
		if 'json' in v.table.imports {
			cgen.genln('
#define js_get(object, key) cJSON_GetObjectItemCaseSensitive((object), (key))
')
		}
	}
	if '-debug_alloc' in os.args {
		cgen.genln('#define DEBUG_ALLOC 1')
	}
	//cgen.genln('/*================================== FNS =================================*/')
	cgen.genln('this line will be replaced with definitions')
	defs_pos := cgen.lines.len - 1
	for file in v.files {
		mut p := v.new_parser(file)
		p.parse(.main)
		// p.g.gen_x64()
		// Format all files (don't format automatically generated vlib headers)
		if !v.pref.nofmt && !file.contains('/vlib/') {
			// new vfmt is not ready yet
		}
	}
	v.log('Done parsing.')
	// Write everything
	mut d := strings.new_builder(10000)// Avoid unnecessary allocations
	$if !js {
		d.writeln(cgen.includes.join_lines())
		d.writeln(cgen.typedefs.join_lines())
		d.writeln(v.type_definitions())
		d.writeln('\nstring _STR(const char*, ...);\n')
		d.writeln('\nstring _STR_TMP(const char*, ...);\n')
		d.writeln(cgen.fns.join_lines()) // fn definitions
	} $else {
		d.writeln(v.type_definitions())
	}
	d.writeln(cgen.consts.join_lines())
	d.writeln(cgen.thread_args.join_lines())
	if v.pref.is_prof {
		d.writeln('; // Prof counters:')
		d.writeln(v.prof_counters())
	}
	dd := d.str()
	cgen.lines[defs_pos] = dd// TODO `def.str()` doesn't compile
	v.generate_main()
	v.generate_hot_reload_code()
	if v.pref.is_verbose {
		v.log('flags=')
		for flag in v.get_os_cflags() {
			println(' * ' + flag.format())
		}
	}
	$if js {
		cgen.genln('main();')
	}	
	cgen.save()
	v.cc()
}

fn (v mut V) generate_main() {
	mut cgen := v.cgen
	$if js { return }

	// if v.build_mode in [.default, .embed_vlib] {
	if v.pref.build_mode == .default_mode || v.pref.build_mode == .embed_vlib {
		mut consts_init_body := cgen.consts_init.join_lines()
		for imp in v.table.imports {
			if imp == 'http' {
				consts_init_body += '\n http__init_module();'
			}
		}
		// vlib can't have `init_consts()`
		cgen.genln('void init_consts() {
#ifdef _WIN32
DWORD consoleMode;
BOOL isConsole = GetConsoleMode(GetStdHandle(STD_INPUT_HANDLE), &consoleMode);
int mode = isConsole ? _O_U16TEXT : _O_U8TEXT;
_setmode(_fileno(stdin), mode);
_setmode(_fileno(stdout), _O_U8TEXT);
SetConsoleMode(GetStdHandle(STD_OUTPUT_HANDLE), ENABLE_PROCESSED_OUTPUT | 0x0004);
// ENABLE_VIRTUAL_TERMINAL_PROCESSING
setbuf(stdout,0);
#endif
g_str_buf=malloc(1000);
$consts_init_body
}')
		// _STR function can't be defined in vlib
		cgen.genln('
string _STR(const char *fmt, ...) {
	va_list argptr;
	va_start(argptr, fmt);
	size_t len = vsnprintf(0, 0, fmt, argptr) + 1;
	va_end(argptr);
	byte* buf = malloc(len);
	va_start(argptr, fmt);
	vsprintf((char *)buf, fmt, argptr);
	va_end(argptr);
#ifdef DEBUG_ALLOC
	puts("_STR:");
	puts(buf);
#endif
	return tos2(buf);
}

string _STR_TMP(const char *fmt, ...) {
	va_list argptr;
	va_start(argptr, fmt);
	//size_t len = vsnprintf(0, 0, fmt, argptr) + 1;
	va_end(argptr);
	va_start(argptr, fmt);
	vsprintf((char *)g_str_buf, fmt, argptr);
	va_end(argptr);
#ifdef DEBUG_ALLOC
	//puts("_STR_TMP:");
	//puts(g_str_buf);
#endif
	return tos2(g_str_buf);
}

')
	}

	// Make sure the main function exists
	// Obviously we don't need it in libraries
	if v.pref.build_mode != .build_module {
		if !v.table.main_exists() && !v.pref.is_test {
			// It can be skipped in single file programs
			if v.pref.is_script {
				//println('Generating main()...')
				cgen.genln('int main() { init_consts();')
				cgen.genln('$cgen.fn_main;')
				cgen.genln('return 0; }')
			}
			else {
				println('panic: function `main` is undeclared in the main module')
				exit(1)
			}
		}
		else if v.pref.is_test {
			if v.table.main_exists() {
				cerror('test files cannot have function `main`')
			}	
			// make sure there's at least on test function
			if !v.table.has_at_least_one_test_fn() {
				cerror('test files need to have at least one test function')
			}	
			// Generate `main` which calls every single test function
			cgen.genln('int main() { init_consts();')
			for _, f in v.table.fns {
				if f.name.starts_with('test_') {
					cgen.genln('$f.name();')
				}
			}
			cgen.genln('return g_test_ok == 0; }')
		}
	}
}

fn final_target_out_name(out_name string) string {
	mut cmd := if out_name.starts_with('/') {
		out_name
	}
	else {
		'./' + out_name
	}
	$if windows {
		cmd = out_name
		cmd = cmd.replace('/', '\\')
		cmd += '.exe'
	}
	return cmd
}

fn (v V) run_compiled_executable_and_exit() {
	if v.pref.is_verbose {
		println('============ running $v.out_name ============')
	}	
	mut cmd := '"' + final_target_out_name(v.out_name).replace('.exe','') + '"'
	if os.args.len > 3 {
		cmd += ' ' + os.args.right(3).join(' ')
	}
	if v.pref.is_test {
		ret := os.system(cmd)
		if ret != 0 {
			exit(1)
		}
	}
	if v.pref.is_run {
		ret := os.system(cmd)
		// TODO: make the runner wrapping as transparent as possible
		// (i.e. use execve when implemented). For now though, the runner
		// just returns the same exit code as the child process
		// (see man system, man 2 waitpid: C macro WEXITSTATUS section)
		exit( ret >> 8 )
	}
	exit(0)
}

fn (v &V) v_files_from_dir(dir string) []string {
	mut res := []string
	if !os.file_exists(dir) {
		cerror('$dir doesn\'t exist')
	} else if !os.dir_exists(dir) {
		cerror('$dir isn\'t a directory')
	}
	mut files := os.ls(dir)
	if v.pref.is_verbose {
		println('v_files_from_dir ("$dir")')
	}
	files.sort()
	for file in files {
		if !file.ends_with('.v') && !file.ends_with('.vh') {
			continue
		}
		if file.ends_with('_test.v') {
			continue
		}
		if file.ends_with('_win.v') && (v.os != .windows && v.os != .msvc) {
			continue
		}
		if file.ends_with('_lin.v') && v.os != .linux {
			continue
		}
		if file.ends_with('_mac.v') && v.os != .mac {
			continue
		}
		if file.ends_with('_js.v') && v.os != .js {
			continue
		}
		if file.ends_with('_nix.v') && (v.os == .windows || v.os == .msvc) {
			continue
		}
		if file.ends_with('_js.v') && v.os != .js {
			continue
		}
		if file.ends_with('_c.v') && v.os == .js {
			continue
		}
		res << '$dir/$file'
	}
	return res
}

// Parses imports, adds necessary libs, and then user files
fn (v mut V) add_v_files_to_compile() {
	mut dir := v.dir
	v.log('add_v_files($dir)')
	// Need to store user files separately, because they have to be added after libs, but we dont know
	// which libs need to be added yet
	mut user_files := []string
	// v volt/slack_test.v: compile all .v files to get the environment
	// I need to implement user packages! TODO
	is_test_with_imports := dir.ends_with('_test.v') &&
	(dir.contains('/volt') || dir.contains('/c2volt'))// TODO
	if is_test_with_imports {
		user_files << dir
		pos := dir.last_index('/')
		dir = dir.left(pos) + '/'// TODO WHY IS THIS .neEDED?
	}
	if dir.ends_with('.v') {
		// Just compile one file and get parent dir
		user_files << dir
		dir = dir.all_before('/')
	}
	else {
		// Add .v files from the directory being compiled
		files := v.v_files_from_dir(dir)
		for file in files {
			user_files << file
		}
	}
	if user_files.len == 0 {
		println('No input .v files')
		exit(1)
	}
	if v.pref.is_verbose {
		v.log('user_files:')
		println(user_files)
	}
	// Parse builtin imports
	for file in v.files {
		mut p := v.new_parser(file)
		p.parse(.imports)
	}
	// Parse user imports
	for file in user_files {
		mut p := v.new_parser(file)
		p.parse(.imports)
	}
	// Parse lib imports
/*
	if v.pref.build_mode == .default_mode {
		// strange ( for mod in v.table.imports ) dosent loop all items
		// for mod in v.table.imports {
		for i := 0; i < v.table.imports.len; i++ {
			mod := v.table.imports[i]
			mod_path := v.module_path(mod)
			import_path := '$ModPath/vlib/$mod_path'
			vfiles := v.v_files_from_dir(import_path)
			if vfiles.len == 0 {
				cerror('cannot import module $mod (no .v files in "$import_path").')
			}
			// Add all imports referenced by these libs
			for file in vfiles {
				mut p := v.new_parser(file, Pass.imports)
				p.parse()
			}
		}
	}
	else {
*/
	// strange ( for mod in v.table.imports ) dosent loop all items
	// for mod in v.table.imports {
	for i := 0; i < v.table.imports.len; i++ {
		mod := v.table.imports[i]
		import_path := v.find_module_path(mod)
		vfiles := v.v_files_from_dir(import_path)
		if vfiles.len == 0 {
			cerror('cannot import module $mod (no .v files in "$import_path").')
		}
		// Add all imports referenced by these libs
		for file in vfiles {
			mut p := v.new_parser(file)
			p.parse(.imports)
		}
	}
	if v.pref.is_verbose {
		v.log('imports:')
		println(v.table.imports)
	}
	// graph deps
	mut dep_graph := new_dep_graph()
	dep_graph.from_import_tables(v.table.file_imports)
	deps_resolved := dep_graph.resolve()
	if !deps_resolved.acyclic {
		deps_resolved.display()
		cerror('Import cycle detected.')
	}
	// add imports in correct order
	for mod in deps_resolved.imports() {
		// Building this module? Skip. TODO it's a hack.
		if mod == v.mod {
			continue
		}
		mod_path := v.find_module_path(mod)
		// If we are in default mode, we don't parse vlib .v files, but header .vh files in
		// TmpPath/vlib
		// These were generated by vfmt
/*
		if v.pref.build_mode == .default_mode || v.pref.build_mode == .build_module {
			module_path = '$ModPath/vlib/$mod_p'
		}
*/
		if mod == 'builtin' { continue } // builtin files were already added
		vfiles := v.v_files_from_dir(mod_path)
		for file in vfiles {
			if !(file in v.files) {
				v.files << file
			}
		}
	}
	// Add remaining user files
	mut j := 0
	mut len := -1
	for i, fit in v.table.file_imports {
		// Don't add a duplicate; builtin files are always there
		if fit.file_path in v.files || fit.module_name == 'builtin' {
			continue
		}
		if len == -1 {
			len = i
		}
		j++
		// TODO remove this once imports work with .build
		if v.pref.build_mode == .build_module && j >= len / 2{
			break
		}
		//println(fit)
		//println('fit $fit.file_path')
		v.files << fit.file_path
	}
}

fn get_arg(joined_args, arg, def string) string {
	return get_all_after(joined_args, '-$arg', def)
}

fn get_all_after(joined_args, arg, def string) string {
	key := '$arg '
	mut pos := joined_args.index(key)
	if pos == -1 {
		return def
	}
	pos += key.len
	mut space := joined_args.index_after(' ', pos)
	if space == -1 {
		space = joined_args.len
	}
	res := joined_args.substr(pos, space)
	// println('get_arg($arg) = "$res"')
	return res
}

fn (v &V) module_path(mod string) string {
	// submodule support
	if mod.contains('.') {
		//return mod.replace('.', os.PathSeparator)
		return mod.replace('.', '/')
	}
	return mod
}

fn (v &V) log(s string) {
	if !v.pref.is_verbose {
		return
	}
	println(s)
}

fn new_v(args[]string) &V {
	joined_args := args.join(' ')
	target_os := get_arg(joined_args, 'os', '')
	mut out_name := get_arg(joined_args, 'o', 'a.out')

	mut dir := args.last()
	if 'run' in args {
		dir = get_all_after(joined_args, 'run', '')
	}
	if dir.ends_with(os.PathSeparator) {
		dir = dir.all_before_last(os.PathSeparator)
	}
	if args.len < 2 {
		dir = ''
	}
	// println('new compiler "$dir"')
	// build mode
	mut build_mode := BuildMode.default_mode
	mut mod := ''
	//if args.contains('-lib') {
	if joined_args.contains('build module ') {
		build_mode = .build_module
		// v build module ~/v/os => os.o
		//mod = os.dir(dir)
		mod = if dir.contains(os.PathSeparator) {
			dir.all_after(os.PathSeparator)
		} else {
			dir
		}
		println('Building module "${mod}" (dir="$dir")...')
		//out_name = '$TmpPath/vlib/${base}.o'
		out_name = mod + '.o'
		// Cross compiling? Use separate dirs for each os
/*
		if target_os != os.user_os() {
			os.mkdir('$TmpPath/vlib/$target_os')
			out_name = '$TmpPath/vlib/$target_os/${base}.o'
			println('target_os=$target_os user_os=${os.user_os()}')
			println('!Cross compiling $out_name')
		}
*/
	}
	// TODO embed_vlib is temporarily the default mode. It's much slower.
	else if !('-embed_vlib' in args) {
		build_mode = .embed_vlib
	}
	//
	is_test := dir.ends_with('_test.v')
	is_script := dir.ends_with('.v')
	if is_script && !os.file_exists(dir) {
		println('`$dir` does not exist')
		exit(1)
	}
	// No -o provided? foo.v => foo
	if out_name == 'a.out' && dir.ends_with('.v') {
		out_name = dir.left(dir.len - 2)
	}
	// if we are in `/foo` and run `v .`, the executable should be `foo`
	if dir == '.' && out_name == 'a.out' {
		base := os.getwd().all_after(os.PathSeparator)
		out_name = base.trim_space()
	}
	mut _os := OS.mac
	// No OS specifed? Use current system
	if target_os == '' {
		$if linux {
			_os = .linux
		}
		$if mac {
			_os = .mac
		}
		$if windows {
			_os = .windows
		}
		$if freebsd {
			_os = .freebsd
		}
		$if openbsd {
			_os = .openbsd
		}
		$if netbsd {
			_os = .netbsd
		}
		$if dragonfly {
			_os = .dragonfly
		}
	}
	else {
		switch target_os {
		case 'linux': _os = .linux
		case 'windows': _os = .windows
		case 'mac': _os = .mac
		case 'freebsd': _os = .freebsd
		case 'openbsd': _os = .openbsd
		case 'netbsd': _os = .netbsd
		case 'dragonfly': _os = .dragonfly
		case 'msvc': _os = .msvc
		case 'js': _os = .js
		}
	}
	//println('OS=$_os')
	builtin := 'builtin.v'
	builtins := [
	'array.v',
	'string.v',
	'builtin.v',
	'int.v',
	'utf8.v',
	'map.v',
	'option.v',
	]
	//println(builtins)
	// Location of all vlib files
	vroot := os.dir(os.executable())
	//println('VROOT=$vroot')
	// v.exe's parent directory should contain vlib
	if !os.dir_exists(vroot) || !os.dir_exists(vroot + '/vlib/builtin') {
		println('vlib not found. It should be next to the V executable. ')
		println('Go to https://vlang.io to install V.')
		exit(1)
	}
	//println('out_name:$out_name')
	mut out_name_c := os.realpath( out_name ) + '.tmp.c'
	mut files := []string
	// Add builtin files
	//if !out_name.contains('builtin.o') {
		for builtin in builtins {
			mut f := '$vroot/vlib/builtin/$builtin'
			__ := 1
			$if js {
				f = '$vroot/vlib/builtin/js/$builtin'
			}
			// In default mode we use precompiled vlib.o, point to .vh files with signatures
			if build_mode == .default_mode || build_mode == .build_module {
				//f = '$TmpPath/vlib/builtin/${builtin}h'
			}
			files << f
		}

	cflags := get_cmdline_cflags(args)

	rdir := os.realpath( dir )
	rdir_name := os.filename( rdir )

	obfuscate := '-obf' in args
	is_repl := '-repl' in args
	pref := &Preferences {
		is_test: is_test
		is_script: is_script
		is_so: '-shared' in args
		is_prod: '-prod' in args
		is_verbose: '-verbose' in args || '--verbose' in args
		is_debuggable: '-g' in args
		is_debug: '-debug' in args || '-g' in args
		obfuscate: obfuscate
		is_prof: '-prof' in args
		is_live: '-live' in args
		sanitize: '-sanitize' in args
		nofmt: '-nofmt' in args
		show_c_cmd: '-show_c_cmd' in args
		translated: 'translated' in args
		is_run: 'run' in args
		autofree: '-autofree' in args
		compress: '-compress' in args
		is_repl: is_repl
		build_mode: build_mode
		cflags: cflags
		ccompiler: find_c_compiler()
		building_v: !is_repl && (rdir_name == 'compiler'  || dir.contains('vlib'))
	}
	if pref.is_verbose || pref.is_debug {
		println('C compiler=$pref.ccompiler')
	}
	if pref.is_so {
		out_name_c = out_name.all_after(os.PathSeparator) + '_shared_lib.c'
	}
	return &V{
		os: _os
		out_name: out_name
		files: files
		dir: dir
		lang_dir: vroot
		table: new_table(obfuscate)
		out_name_c: out_name_c
		cgen: new_cgen(out_name_c)
		vroot: vroot
		pref: pref
		mod: mod
	}
}

fn env_vflags_and_os_args() []string {
   mut args := []string
   vflags := os.getenv('VFLAGS')
   if '' != vflags {
	 args << os.args[0]
	 args << vflags.split(' ')
	 if os.args.len > 1 {
	   args << os.args.right(1)
	 }
   }else{
	 args << os.args
   }
   return args
}

fn update_v() {
	println('Updating V...')
	vroot := os.dir(os.executable())
	s := os.exec('git -C "$vroot" pull --rebase origin master') or {
		cerror(err)
		return
	}
	println(s.output)
	$if windows {
		v_backup_file := '$vroot/v_old.exe'
		if os.file_exists( v_backup_file ) {
			os.rm( v_backup_file )
		}
		os.mv('$vroot/v.exe', v_backup_file)
		s2 := os.exec('"$vroot/make.bat"') or {
			cerror(err)
			return
		}
		println(s2.output)
	} $else {
		s2 := os.exec('make -C "$vroot"') or {
			cerror(err)
			return
		}
		println(s2.output)
	}
}

fn vfmt(args[]string) {
	file := args.last()
	if !os.file_exists(file) {
		println('"$file" does not exist')
		exit(1)
	}
	if !file.ends_with('.v') {
		println('v fmt can only be used on .v files')
		exit(1)
	}
	println('vfmt is temporarily disabled')
}

fn install_v(args[]string) {
	if args.len < 3 {
		println('usage: v install [module] [module] [...]')
		return
	}
	names := args.slice(2, args.len)
	vexec := os.executable()
	vroot := os.dir(vexec)
	vget := '$vroot/tools/vget'
	if true {
		//println('Building vget...')
		os.chdir(vroot + '/tools')
		vgetcompilation := os.exec('$vexec -o $vget vget.v') or {
			cerror(err)
			return
		}
		if vgetcompilation.exit_code != 0 {
			cerror( vgetcompilation.output )
			return
		}
	}
	vgetresult := os.exec('$vget ' + names.join(' ')) or {
		cerror(err)
		return
	}
	if vgetresult.exit_code != 0 {
		cerror( vgetresult.output )
		return
	}
}

fn (v &V) test_v() {
	if !os.dir_exists('vlib') {
		println('run "v test v" next to the vlib/ directory')
		exit(1)
	}	
	args := env_vflags_and_os_args()
	vexe := args[0]
	// Emily: pass args from the invocation to the test
	// e.g. `v -g -os msvc test v` -> `$vexe -g -os msvc $file`
	mut joined_args := args.right(1).join(' ')
	joined_args = joined_args.left(joined_args.last_index('test'))
	//	println('$joined_args')
	mut failed := false
	test_files := os.walk_ext('.', '_test.v')

	println('Testing...')
	mut tmark := benchmark.new_benchmark()
	for dot_relative_file in test_files {		
		relative_file := dot_relative_file.replace('./', '')
		file := os.realpath( relative_file )
		tmpcfilepath := file.replace('_test.v', '_test.tmp.c')
		
		mut cmd := '"$vexe" $joined_args -debug "$file"'
		if os.user_os() == 'windows' { cmd = '"$cmd"' }
		
		tmark.step()
		r := os.exec(cmd) or {
			tmark.fail()
			failed = true
			println(tmark.step_message('$relative_file FAIL'))
			continue
		}
		if r.exit_code != 0 {
			failed = true
			tmark.fail()
			println(tmark.step_message('$relative_file FAIL \n`$file`\n (\n$r.output\n)'))
		} else {
			tmark.ok()
			println(tmark.step_message('$relative_file OK'))
		}
		os.rm( tmpcfilepath )
	}
	tmark.stop()
	println( tmark.total_message('running V tests') )

	println('\nBuilding examples...')
	examples := os.walk_ext('examples', '.v')
	mut bmark := benchmark.new_benchmark()
	for relative_file in examples {
		file := os.realpath( relative_file )
		tmpcfilepath := file.replace('.v', '.tmp.c')
		mut cmd := '"$vexe" $joined_args -debug "$file"'
		if os.user_os() == 'windows' { cmd = '"$cmd"' }
		bmark.step()
		r := os.exec(cmd) or {
			failed = true
			bmark.fail()
			println(bmark.step_message('$relative_file FAIL'))
			continue
		}
		if r.exit_code != 0 {
			failed = true
			bmark.fail()
			println(bmark.step_message('$relative_file FAIL \n`$file`\n (\n$r.output\n)'))
		} else {
			bmark.ok()
			println(bmark.step_message('$relative_file OK'))
		}
		os.rm(tmpcfilepath)
	}
	bmark.stop()
	println( bmark.total_message('building examples') )
	
	if failed {
		exit(1)
	}
}

fn create_symlink() {
	vexe := os.executable()
	link_path := '/usr/local/bin/v'
	ret := os.system('ln -sf $vexe $link_path')
	if ret == 0 {
		println('symlink "$link_path" has been created')
	} else {
		println('failed to create symlink "$link_path", '+
			'make sure you run with sudo')
	}
}

pub fn cerror(s string) {
	println('V error: $s')
	os.flush_stdout()
	exit(1)
}

fn vhash() string {
	mut buf := [50]byte
	buf[0] = 0
	C.snprintf(*char(buf), 50, '%s', C.V_COMMIT_HASH )
	return tos_clone(buf)
}
