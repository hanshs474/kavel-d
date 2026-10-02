# kavel

Generate AI images from D with **no API key and no account**.

```bash
dub add kavel
```

```d
import kavel;
import std.stdio;

void main()
{
    Options o;
    o.aspectRatio = "16:9";
    auto r = generate("matte black ceramic mug on pale oak, soft window light", o);
    if (r.ok) writeln(r.image.url);   // https://cdn.kavel.ai/uploads/kie/image/....webp
    else writeln(r.reason, ": ", r.message);
}
```

Or from the shell: `dub run kavel --config=cli -- "an isometric coffee shop, pastel palette"`.

Every other image client wants a key from OpenAI, fal or Replicate before it runs once. This one
calls the anonymous tier of [Kavel](https://www.kavel.ai/?utm_source=dub&utm_medium=package), an
online AI image and video studio, with a client id it invents instead of an account you register.
Phobos only (`std.net.curl`, so libcurl must be present at run time).

## Results you can branch on

Nothing throws. `r.reason` is `Reason.quota` (wait, or pass a key), `Reason.rejected` (reword the
prompt), `Reason.signIn`, `Reason.auth`, `Reason.timeout` or `Reason.other`.

## The free tier

`credits(remaining, grant)` reads what a fresh client id is granted, and the call costs nothing. On
2026-10-02 the grant was 5 credits, one generated image spent all five, and one IP got two images that day.
Free output is 1K and watermarked, and free runs queue before the model starts, so the default
deadline is six minutes.

## Editing a photo

```d
Options o;
o.apiKey = environment.get("KAVEL_API_KEY");
auto r = edit("https://example.com/portrait.jpg",
              "shoulder-length layered haircut, keep the same face, skin and lighting", o);
```

An edit costs more than the free grant, so it needs a key from
[kavel.ai/settings/apikeys](https://www.kavel.ai/settings/apikeys?utm_source=dub&utm_medium=package).
Without one it returns `Reason.quota` before anything is charged.

## License

MIT. Generated with [Kavel AI](https://www.kavel.ai/?utm_source=dub&utm_medium=package).
