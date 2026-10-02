/// kavel "an isometric coffee shop, pastel palette"
import std.array : join;
import std.stdio;
import kavel;

int main(string[] args)
{
    auto prompt = args[1 .. $].join(" ");
    if (!prompt.length) { stderr.writeln(`usage: kavel "your prompt"`); return 2; }
    auto r = generate(prompt);
    if (!r.ok) { stderr.writeln(r.reason, ": ", r.message); return 1; }
    writeln(r.image.url);
    return 0;
}
