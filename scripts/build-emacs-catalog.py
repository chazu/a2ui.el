#!/usr/bin/env python3
"""Build catalogs/emacs/catalog.json: the basic catalog plus Emacs components.

The Emacs catalog is a superset, so a surface can mix Text and Button
with Diff and Table under one catalogId.  Basic components the renderer
cannot draw are left out until it can (none at present).

    python3 scripts/build-emacs-catalog.py
"""

import copy
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG_ID = "https://github.com/chazu/a2ui.el/catalogs/emacs/v0.1"
COMMON = "https://a2ui.org/specification/v0_9/common_types.json#/$defs/"
UNSUPPORTED = set()
TONES = ["success", "warning", "error", "muted"]
TONE_DIGEST = "|".join(TONES)
# How the basic components that act differently in Emacs behave.
BASIC_DIGESTS = {
    "Text": f"Text: text:str variant?:h1|h2|h3|h4|h5|caption|body tone?:{TONE_DIGEST}  (tone colours it; may be bound)",
    "Tabs": "Tabs: tabs:[{title:str child:id}]  (only the selected tab's child is shown; switching tabs sends nothing)",
    "Modal": "Modal: trigger:id content:id  (trigger, usually a Button, opens content in a popup window; that press sends nothing)",
}


def ref(name, description=None):
    out = {"$ref": COMMON + name}
    if description:
        out["description"] = description
    return out


def tone(description="Colours it: success, warning, error or muted.  May be bound to data."):
    return ref("DynamicString", description)


def component(name, description, digest, properties, required, checkable=False):
    """A component schema in the shape the basic catalog uses."""
    return {
        "type": "object",
        "description": description,
        "x-a2ui-digest": digest,
        "allOf": [
            {"$ref": COMMON + "ComponentCommon"},
            {"$ref": "#/$defs/CatalogComponentCommon"},
            *([{"$ref": COMMON + "Checkable"}] if checkable else []),
            {"type": "object",
             "properties": {"component": {"const": name}, **properties},
             "required": ["component", *required]},
        ],
        "unevaluatedProperties": False,
    }


EMACS = {
    "Section": component(
        "Section",
        "A collapsible section with a title, folded and unfolded with RET or TAB on its heading.",
        "Section: title:str child:id collapsed?:bool  (group or fold secondary detail; RET/TAB toggles)",
        {"title": ref("DynamicString", "The heading."),
         "child": ref("ComponentId", "The content shown when unfolded."),
         "collapsed": ref("DynamicBoolean", "Whether it starts folded; when bound, toggling writes it.")},
        ["title", "child"]),
    "Table": component(
        "Table",
        "A table of rows from the data model, with optional row selection and a row action.",
        "Table: columns:[{label:str key:string align?:left|right|center toneKey?:string display?:text|bar|sparkline "
        "min?:number max?:number}] rows:path|[objects] rowKey?:string "
        "selectable?:none|single|multiple selection?:path rowAction?:action  "
        "(any list of records: files, items, results; key names a row field; selection gets rowKey values; "
        "rowAction runs on RET with paths relative to the row; toneKey names a row field holding the cell's "
        f"tone, {TONE_DIGEST}; display bar draws a number between min (0) and max (1), sparkline an array of numbers)",
        {"columns": {"type": "array", "items": {
            "type": "object",
            "properties": {"label": ref("DynamicString"), "key": {"type": "string"},
                           "align": {"type": "string", "enum": ["left", "right", "center"]},
                           "toneKey": {"type": "string",
                                       "description": "The row field holding this cell's tone: " + ", ".join(TONES) + "."},
                           "display": {"type": "string", "enum": ["text", "bar", "sparkline"], "default": "text",
                                       "description": "bar draws a number as a bar; sparkline draws an array of numbers."},
                           "min": {"type": "number", "description": "The bottom of the scale; bar defaults to 0, sparkline to the cell's least value."},
                           "max": {"type": "number", "description": "The top of the scale; bar defaults to 1, sparkline to the cell's greatest value."}},
            "required": ["label", "key"]}},
         "rows": ref("DynamicValue", "An array of row objects, usually {\"path\": ...}."),
         "rowKey": {"type": "string", "description": "The row field that identifies a row."},
         "selectable": {"type": "string", "enum": ["none", "single", "multiple"], "default": "none"},
         "selection": ref("DataBinding", "Where the selected row key (or keys) is written."),
         "rowAction": ref("Action", "Run on RET on a row; relative paths resolve against the row.")},
        ["columns", "rows"]),
    "Diff": component(
        "Diff",
        "A unified diff, fontified like diff-mode, with optional Accept and Reject buttons.",
        "Diff: diff:str file?:str acceptAction?:action rejectAction?:action selection?:path edited?:path  "
        "(a proposed change to one file, as unified diff text; with selection the user ticks hunks and their "
        "indices from 0 are written there, unset meaning all; when file exists the user may open it in Ediff, and with "
        "edited their edited result is written there as a unified diff; put both paths in acceptAction's context)",
        {"diff": ref("DynamicString", "Unified diff text."),
         "file": ref("DynamicString", "The file the diff applies to, shown as a heading.  When it exists, "
                     "relative to the project, the user can open the change in Ediff."),
         "acceptAction": ref("Action"), "rejectAction": ref("Action"),
         "selection": ref("DataBinding", "Lets the user pick hunks; their indices from 0 are written here.  "
                          "Unset or null means every hunk."),
         "edited": ref("DataBinding", "Where the user's edit in Ediff is written, as a unified diff against the file.")},
        ["diff"]),
    "Progress": component(
        "Progress",
        "A bar showing how far a value has got between min and max, with a label and text after it.",
        f"Progress: value:num max?:num min?:num label?:str text?:str tone?:{TONE_DIGEST}  "
        "(a bar from min (0) to max (1); text replaces the percentage shown after it)",
        {"value": ref("DynamicNumber"),
         "min": ref("DynamicNumber", "The empty end; 0 by default."),
         "max": ref("DynamicNumber", "The full end; 1 by default."),
         "label": ref("DynamicString"),
         "text": ref("DynamicString", "Shown after the bar instead of the percentage, e.g. \"3/6 pods\"."),
         "tone": tone()},
        ["value"]),
    "Sparkline": component(
        "Sparkline",
        "A one-line chart of a series of numbers, oldest first.",
        f"Sparkline: values:path|[numbers] min?:num max?:num label?:str text?:str tone?:{TONE_DIGEST}  "
        "(a trend, oldest first; null is a gap; scaled to min and max, by default the values' own range)",
        {"values": ref("DynamicValue", "An array of numbers, oldest first; null leaves a gap."),
         "min": ref("DynamicNumber"), "max": ref("DynamicNumber"),
         "label": ref("DynamicString"),
         "text": ref("DynamicString", "Shown after the chart, e.g. the latest value."),
         "tone": tone()},
        ["values"]),
    "Code": component(
        "Code",
        "Source code fontified with the language's major mode.",
        "Code: text:str language?:string  (source, commands or config, fontified; language e.g. python, elisp, sh, json, yaml)",
        {"text": ref("DynamicString"), "language": {"type": "string"}},
        ["text"]),
    "Picker": component(
        "Picker",
        "One choice from a list, picked with completion; options may come from the data model.",
        "Picker: options:strs|[{label:str value:string}]|path value:str label?:str  (choose one of many by completion; options may be bound to data)",
        {"label": ref("DynamicString"),
         "options": ref("DynamicValue", "Strings, or {label, value} objects, literal or bound."),
         "value": ref("DynamicString", "Bound to the chosen value.")},
        ["options", "value"], checkable=True),
    "FileRef": component(
        "FileRef",
        "A link that visits a file, optionally at a line.  Relative paths start at the project.",
        "FileRef: path:str line?:num label?:str  (a link the user follows to that file and line; paths relative to the project)",
        {"path": ref("DynamicString"), "line": ref("DynamicNumber"), "label": ref("DynamicString")},
        ["path"]),
    "OrgText": component(
        "OrgText",
        "Read-only text in Org markup, shown with Org's faces.",
        "OrgText: text:str  (longer prose in Org markup: *bold* /italic/ =code= [[url][links]], headings, lists)",
        {"text": ref("DynamicString")},
        ["text"]),
}

basic = json.loads((ROOT / "catalogs/basic/catalog.json").read_text())
catalog = copy.deepcopy(basic)
catalog["$id"] = CATALOG_ID
catalog["catalogId"] = CATALOG_ID
catalog["title"] = "a2ui.el Emacs catalog"
catalog["description"] = ("The A2UI v0.9 basic catalog plus Emacs components: "
                          "Section, Table, Diff, Code, Picker, FileRef, OrgText, Progress and Sparkline.  Prefer them to "
                          "building the same thing from Rows and Text.  Any component takes visible?:bool, "
                          "usually bound to data, to show or hide it without sending components again.")
# Every component may be shown or hidden from the data model.
catalog["$defs"]["CatalogComponentCommon"]["properties"]["visible"] = ref(
    "DynamicBoolean", "Whether the component is shown; false hides it and its children.  Defaults to true.")
# Text takes a tone in Emacs.
text_props = next(part for part in catalog["components"]["Text"]["allOf"]
                  if isinstance(part, dict) and "properties" in part)["properties"]
text_props["tone"] = tone()
for name in UNSUPPORTED:
    catalog["components"].pop(name, None)
for name, digest in BASIC_DIGESTS.items():
    catalog["components"][name]["x-a2ui-digest"] = digest
catalog["components"].update(EMACS)
any_component = catalog["$defs"].get("anyComponent")
if isinstance(any_component, dict) and "oneOf" in any_component:
    any_component["oneOf"] = [{"$ref": f"#/components/{n}"} for n in catalog["components"]]

out = ROOT / "catalogs/emacs/catalog.json"
out.write_text(json.dumps(catalog, indent=2, ensure_ascii=False) + "\n")
print(f"wrote {out.relative_to(ROOT)}: {len(catalog['components'])} components")
