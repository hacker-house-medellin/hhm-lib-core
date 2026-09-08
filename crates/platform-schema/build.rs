use std::{env, fs, path::PathBuf};

fn main() {
    let manifest = PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("manifest directory"));
    let repository = manifest.join("../..");
    let output = PathBuf::from(env::var("OUT_DIR").expect("build output directory"));

    for (source, target) in [
        ("vendor/hhm-interfaces/platform/rust/types.rs", "types.rs"),
        (
            "vendor/hhm-interfaces/platform/seaorm/entities.rs",
            "entities.rs",
        ),
        (
            "vendor/hhm-interfaces/platform/diesel/schema.rs",
            "schema.rs",
        ),
    ] {
        let source_path = repository.join(source);
        println!("cargo:rerun-if-changed={}", source_path.display());
        let contents = fs::read_to_string(&source_path).expect("read vendored platform projection");
        let sanitized = contents
            .lines()
            .filter(|line| !line.starts_with("#!["))
            .collect::<Vec<_>>()
            .join("\n");
        fs::write(output.join(target), format!("{sanitized}\n"))
            .expect("write generated compile witness");
    }
}
