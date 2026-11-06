use anyhow::Result;
fn main() -> Result<()> {
    let mut resolve = wit_parser::Resolve::default();
    let (pkg, _) = resolve.push_dir(std::env::args().nth(1).unwrap_or("wit".into()))?;
    let world = resolve.select_world(&[pkg], Some("system"))?;
    let bytes = wit_component::metadata::encode(&resolve, world, wit_component::StringEncoding::UTF8, None, false)?;
    std::fs::write(std::env::args().nth(2).unwrap_or("payload.bin".into()), bytes)?;
    Ok(())
}
