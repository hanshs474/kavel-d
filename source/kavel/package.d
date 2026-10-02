/**
 * Generate and edit AI images from D with no API key and no account.
 *
 * ---
 * import kavel;
 * auto r = generate("matte black ceramic mug on pale oak, soft window light");
 * if (r.ok) writeln(r.image.url); else writeln(r.reason, ": ", r.message);
 * ---
 *
 * Without a key this calls the anonymous tier of https://www.kavel.ai, which
 * meters a small free allowance against a client id this module invents rather
 * than an account you register. Set `Options.apiKey` (or KAVEL_API_KEY) to run
 * on your account. Uses std.net.curl, so libcurl must be present at run time.
 */
module kavel;

import core.thread : Thread;
import core.time : seconds;
import std.algorithm : canFind;
import std.conv : to;
import std.datetime.systime : Clock;
import std.format : format;
import std.json;
import std.net.curl : HTTP, get, post, CurlException;
import std.process : environment;
import std.random : uniform;
import std.string : strip, startsWith, toLower;
import std.uri : encodeComponent;

/// Why a call failed, in terms of what to do next.
enum Reason { none, quota, rejected, signIn, auth, timeout, other }

/// One finished picture.
struct Image { string url; bool watermarked; }

/// The outcome of a call.
struct Result { bool ok; Image image; Reason reason; string message; }

/// Settings for one call. `Options.init` is valid.
struct Options
{
    string aspectRatio = "1:1"; /// "1:1", "16:9", "9:16", "4:3" or "3:4"
    string apiKey;              /// key from https://www.kavel.ai/settings/apikeys
    string model;               /// engine override, honoured only with a key
    int pollSeconds = 5;
    int timeoutSeconds = 360;
}

/// Service root, changeable for a test or a proxy.
__gshared string baseUrl = "https://www.kavel.ai";

private Result fail(Reason r, string msg) { return Result(false, Image.init, r, "kavel: " ~ msg); }

private string anonId()
{
    string s = "d-";
    foreach (_; 0 .. 8) s ~= format("%02x", uniform(0, 256));
    return s;
}

private string keyOf(const Options o)
{
    return o.apiKey.length ? o.apiKey : environment.get("KAVEL_API_KEY", "");
}

// Refusals answer HTTP 200 with code -1 and a human message.
private bool request(string url, string[string] headers, string body, out JSONValue data, out Result err)
{
    auto http = HTTP();
    foreach (k, v; headers) http.addRequestHeader(k, v);
    string raw;
    try
    {
        if (body.length)
        {
            http.addRequestHeader("Content-Type", "application/json");
            raw = post(url, body, http).idup;
        }
        else raw = get(url, http).idup;
    }
    catch (Exception e) { err = fail(Reason.other, e.msg); return false; }
    JSONValue env;
    try env = parseJSON(raw);
    catch (Exception) { err = fail(Reason.other, "unexpected response"); return false; }
    auto code = "code" in env;
    if (code is null || code.integer != 0)
    {
        auto m = "message" in env;
        string msg = (m !is null && m.type == JSONType.string) ? m.str : "request refused";
        auto low = msg.toLower;
        Reason r = low.canFind("invalid api key") ? Reason.auth
            : low.canFind("insufficient credits") ? Reason.quota
            : (low.canFind("sign in") || low.canFind("subscription")) ? Reason.signIn
            : Reason.other;
        err = fail(r, msg);
        return false;
    }
    auto d = "data" in env;
    data = d is null ? parseJSON("{}") : *d;
    return true;
}

private string strField(JSONValue v, string k)
{
    if (v.type != JSONType.object) return "";
    auto p = k in v;
    return (p !is null && p.type == JSONType.string) ? p.str : "";
}

private bool boolField(JSONValue v, string k)
{
    if (v.type != JSONType.object) return false;
    auto p = k in v;
    return p !is null && p.type == JSONType.true_;
}

private const(JSONValue)[] arrField(JSONValue v, string k)
{
    if (v.type != JSONType.object) return null;
    auto p = k in v;
    return (p !is null && p.type == JSONType.array) ? p.array : null;
}

private Result run(JSONValue payload, const Options o)
{
    auto key = keyOf(o);
    string[string] auth;
    if (key.length) auth["Authorization"] = "Bearer " ~ key;
    else auth["x-anon-id"] = anonId();
    auto deadline = Clock.currTime + (o.timeoutSeconds > 0 ? o.timeoutSeconds : 360).seconds;

    JSONValue d;
    Result err;
    if (!request(baseUrl ~ "/api/ai/generate", auth, payload.toString, d, err)) return err;
    // The quota wall answers 200 with code 0 and wall: true.
    if (boolField(d, "wall"))
    {
        auto why = strField(d, "reason");
        if (why == "anon_ip_daily") return fail(Reason.quota, "this machine has used its free credits for today");
        if (why == "anon_unmetered_video") return fail(Reason.signIn, "this needs a signed-in account");
        return fail(Reason.quota, "the free allowance does not cover this run");
    }
    auto task = strField(d, "id");
    if (!task.length) return fail(Reason.other, "the service returned no task id");

    while (Clock.currTime < deadline)
    {
        Thread.sleep((o.pollSeconds > 0 ? o.pollSeconds : 5).seconds);
        JSONValue p;
        Result perr;
        bool pok = key.length
            ? request(baseUrl ~ "/api/ai/query", auth, JSONValue(["taskId": task]).toString, p, perr)
            : request(baseUrl ~ "/api/ai/anon-query?taskId=" ~ encodeComponent(task) ~ "&provider=kie&mediaType=image", auth, "", p, perr);
        // Free runs only start when a poll crosses the end of the queue, so a
        // dropped poll is not a failed job: keep going.
        if (!pok) continue;
        auto clean = arrField(p, "cleanImages");
        if (clean.length) return Result(true, Image(clean[0].str, false));
        auto imgs = arrField(p, "images");
        if (imgs.length)
        {
            auto wm = arrField(p, "watermarked");
            return Result(true, Image(imgs[0].str, wm.length && wm[0].type == JSONType.true_));
        }
        auto st = strField(p, "status");
        if (st == "failed" || st == "error") return fail(Reason.rejected, "prompt refused; reword it");
    }
    return fail(Reason.timeout, "no image before the deadline");
}

/// Turns a prompt into a new image. Naming the light, the material and the
/// composition moves the result far more than adding adjectives.
Result generate(string prompt, Options o = Options.init)
{
    if (!prompt.strip.length) return fail(Reason.other, "prompt is required");
    auto model = keyOf(o).length && o.model.length ? o.model : "kavel-image-v1";
    JSONValue p = ["provider": "kie", "mediaType": "image", "model": model, "scene": "text-to-image", "prompt": prompt];
    p["options"] = JSONValue(["aspect_ratio": o.aspectRatio.length ? o.aspectRatio : "1:1"]);
    return run(p, o);
}

/// Rewrites the image at a public url. An edit costs more than the free
/// allowance, so without a key this returns `Reason.quota` before anything is charged.
Result edit(string sourceUrl, string instruction, Options o = Options.init)
{
    if (!(sourceUrl.startsWith("http://") || sourceUrl.startsWith("https://")))
        return fail(Reason.other, "sourceUrl must be a public http(s) url");
    if (!instruction.strip.length) return fail(Reason.other, "instruction is required");
    auto model = keyOf(o).length && o.model.length ? o.model : "nano-banana-2-lite";
    JSONValue p = ["provider": "kie", "mediaType": "image", "model": model, "scene": "image-to-image", "prompt": instruction];
    p["options"] = JSONValue(["image_input": JSONValue([JSONValue(sourceUrl)])]);
    return run(p, o);
}

/// What a fresh anonymous client id is granted. Free to call.
bool credits(out int remaining, out int grant)
{
    JSONValue d;
    Result err;
    if (!request(baseUrl ~ "/api/ai/anon-credits", ["x-anon-id": anonId()], "", d, err)) return false;
    remaining = cast(int) d["remaining"].integer;
    grant = cast(int) d["grant"].integer;
    return true;
}
