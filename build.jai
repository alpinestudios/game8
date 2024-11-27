// this added an extra ~200ms of compile time, maybe there's a similar way to do this in Odin that's faster? Not sure.

// if the shader file changed, it's just calling this before building the game:
// sokol-shdc -i game/shader.glsl -o game/shader.odin -l hlsl5:wgsl -f sokol_odin

#run main();
main :: () {
	
	set_build_options_dc(.{do_output=false, write_added_strings=false});
	build_options := get_build_options();
	args := build_options.compile_time_command_line;
	// log("args: %\n\n", args);
	
	wd := get_working_directory();
	
	// build the shader
	if has_file_changed_since_last_compile("game/shader.glsl") {
		log("recompiling shader");
		result := run_command("sokol-shdc -i game/shader.glsl -o game/shader.odin -l hlsl5:wgsl -f sokol_odin", working_directory=wd, arg_quoting=.NEVER_QUOTE);
		if result.exit_code != 0 {
			log_error("build failed, exit: %", result.exit_code);
			exit(1);
		}
	}
	
	// odin game build
	result := run_command("odin", "build game -debug", working_directory=wd, arg_quoting=.NEVER_QUOTE);
	if result.exit_code != 0 {
		log_error("build failed, exit: %", result.exit_code);
		exit(1);
	}

}

has_file_changed_since_last_compile :: (file_path: string) -> bool {

	hash_name := path_strip_extension((path_filename(file_path)));

	rebuild := true;
	
	source_file, soruce_read := read_entire_file(file_path);
	if !soruce_read
	{
		log_error("source file '%' not found, can't read it for hash caching", file_path);
		return true;
	}
	current_hash := sdbm_hash(source_file.data, source_file.count);
	
	make_directory_if_it_does_not_exist(".build");

	cached_hash : u32;
	cached_hash_file_name := tprint(".build/%", hash_name);
	if file_exists(cached_hash_file_name)
	{
		hash_file, read := read_entire_file(cached_hash_file_name);
		if read
		{
			cached_hash = << cast(*u32)hash_file.data;
			if cached_hash == current_hash
				rebuild = false;
		}
	}
	
	if rebuild
	{
		wrote := write_entire_file(cached_hash_file_name, *current_hash, size_of(type_of(current_hash)));
		// if wrote then log("Cached Hash % to %", current_hash, cached_hash_file_name);
	}

	// log("% % c%, p%", hash_name, rebuild, current_hash, cached_hash);
	return rebuild;
}

#import "Basic";
#import "Compiler";
#import "Process";
#import "File_Utilities";
#import "String";
#import "File";
#import "Hash";