// Minimal stand-in for Terraform's templatefile() for simple templates:
//   ${name}   -> replaced with vars[name]
//   $${...}   -> literal ${...} (Terraform's escape, used for shell variables)
// Anything templatefile() would evaluate as an expression or directive
// (${a + 1}, %{ if }, %{ for }) is rejected with an error rather than
// silently rendered wrong.
export function renderTemplate(template: string, vars: Record<string, string>): string {
    const ESCAPE = "\u0000ESCAPED_INTERP\u0000";

    if (/(^|[^%])%\{/.test(template)) {
        throw new Error("Template uses %{ } directives, which renderTemplate does not support.");
    }

    // Protect escaped $${ so it isn't treated as a template reference.
    let out = template.split("$${").join(ESCAPE);

    out = out.replace(/\$\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*\}/g, (match, key: string) => {
        if (!(key in vars)) {
            throw new Error(`Template references "${key}", which was not provided.`);
        }
        return vars[key];
    });

    // Any remaining ${ is an expression templatefile() would have evaluated.
    const leftover = out.match(/\$\{[^}]*\}/);
    if (leftover) {
        throw new Error(`Unsupported template expression: ${leftover[0]}`);
    }

    return out.split(ESCAPE).join("${").split("%%{").join("%{");
}
