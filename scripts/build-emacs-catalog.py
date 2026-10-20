#!/usr/bin/env python3
"""Build catalogs/emacs/catalog.json: the basic catalog plus Emacs components.

The Emacs catalog is a superset, so a surface can mix Text and Button
with Diff and Table under one catalogId.  Basic components the renderer
cannot draw yet (Tabs, Modal) are left out until it can.

    python3 scripts/build-emacs-catalog.py
"""

import copy
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG_ID = "https://github.com/chazu/a2ui.el/catalogs/emacs/v0.1"
COMMON = "https://a2ui.org/specification/v0_9/common_types.json#/$defs/"
UNSUPPORTED = {"Tabs", "Modal"}


def ref(name, description=None):
    out = {"$ref": COMMON + name}
    if description:
        out["description"] = description
    return out


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
        "Table: columns:[{label:str key:string align?:left|right|center}] rows:path|[objects] rowKey?:string "
        "selectable?:none|single|multiple selection?:path rowAction?:action  "
        "(any list of records: files, items, results; key names a row field; selection gets rowKey values; "
        "rowAction runs on RET with paths relative to the row)",
        {"columns": {"type": "array", "items": {
            "type": "object",
            "properties": {"label": ref("DynamicString"), "key": {"type": "string"},
                           "align": {"type": "string", "enum": ["left", "right", "center"]}},
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
        "Diff: diff:str file?:str acceptAction?:action rejectAction?:action  (a proposed change to one file, as unified diff text)",
        {"diff": ref("DynamicString", "Unified diff text."),
         "file": ref("DynamicString", "The file the diff applies to, shown as a heading."),
         "acceptAction": ref("Action"), "rejectAction": ref("Action")},
        ["diff"]),
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
catalog["description"] = ("The A2UI v0.9 basic catalog (less Tabs and Modal) plus Emacs components: "
                          "Section, Table, Diff, Code, Picker, FileRef and OrgText.  Prefer them to "
                          "building the same thing from Rows and Text.")
for name in UNSUPPORTED:
    catalog["components"].pop(name, None)
catalog["components"].update(EMACS)
any_component = catalog["$defs"].get("anyComponent")
if isinstance(any_component, dict) and "oneOf" in any_component:
    any_component["oneOf"] = [{"$ref": f"#/components/{n}"} for n in catalog["components"]]

out = ROOT / "catalogs/emacs/catalog.json"
out.write_text(json.dumps(catalog, indent=2, ensure_ascii=False) + "\n")
print(f"wrote {out.relative_to(ROOT)}: {len(catalog['components'])} components")
