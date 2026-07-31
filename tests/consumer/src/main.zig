const web_html = @import("web_html");
const web_router = @import("web_router");

pub fn main() void {
    _ = web_html.package_is_initialized;
    _ = web_router.package_is_initialized;
}
