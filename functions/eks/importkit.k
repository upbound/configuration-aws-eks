"""
Brownfield import kit.

A generic, provider-agnostic engine for adopting pre-existing cloud resources
into a Crossplane v2 composition. It works purely on observed composed resources:
each resource's spec.forProvider is treated as the composition's desired state
(the source of truth) and status.atProvider as live cloud state. It therefore
carries no provider-schema dependency and can be reused by any composition.

The composition supplies a small spec - which resources are importable, their
composition-resource-names, which leaf fields map to editable parameters, and
which keys are required - and this module computes the full set of changes a
commit would make, split into reconcilable `drift` and unreconcilable
`sideEffects`.
"""

import regex
import json

schema Change:
    """A single field-level difference between desired (forProvider) and live (atProvider) state.

    An absent `desired` means the field/tag would be removed on commit; an absent
    `observed` means it would be added.
    """
    field: str
    desired?: any
    observed?: any

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

# Dot-separated path getter with default (mirrors the composition's own get()).
_get = lambda x: any, y: str, d: any -> any {
    p = regex.split(y, "\.")
    c = p[0]
    rest = ".".join(p[1::])
    x[c] if len(p) == 1 and c in x else d if c not in x else _get(x[c], rest, d)
}

# Scalar / set-like list handling: AWS set-like fields (subnetIds,
# managedPolicyArns, ...) come back from the cloud in a different order than the
# composition declares them, which is not a real change - compare them as sets.
_isScalar = lambda v: any -> bool {
    typeof(v) in ["str", "int", "float", "bool"]
}
_scalarList = lambda v: any -> bool {
    typeof(v) == "list" and (all e in v { _isScalar(e) })
}
_sameSet = lambda a: any, b: any -> bool {
    len(a) == len(b) and (all e in a { e in b }) and (all e in b { e in a })
}

# JSON-string handling: many cloud fields (IAM assumeRolePolicy, addon
# configurationValues, ...) are JSON serialized into a string; the composition
# declares them pretty-printed / in one key order while the cloud returns them
# compacted / reordered. Detection is structural (no field-name list): a string
# is treated as JSON only if it opens like a JSON object - `{"...` or `{}` - which
# also rejects lookalikes such as Go templates (`{{ ... }}`). `[`-strings are
# intentionally NOT treated as JSON (e.g. `[INFO] ...` is not an array) so
# json.decode never sees non-JSON (KCL cannot recover from a decode error).
_looksJson = lambda s: str -> bool {
    regex.match(s, "^\\s*\\{\\s*(\"|\\})")
}
# Semantic equality via decode; KCL dict equality is key-order independent, so
# this collapses whitespace and key-order differences.
_jsonEqual = lambda a: str, b: str -> bool {
    json.decode(a) == json.decode(b)
}

# Crossplane cross-resource wiring / provider-computed mirrors: never real cloud
# state, so skipping them avoids false positives.
_skipKey = lambda k: str -> bool {
    k.endswith("Ref") or k.endswith("Refs") or k.endswith("Selector") or k == "tagsAll"
}

# Bidirectional diff for open-keyed maps (tags): removals (live but not desired ->
# committing strips them) and additions/updates (desired but not live / changed).
_mapDiff = lambda fp: any, ap: any, path: str -> [any] {
    _rm = [{field = "{}[{}]".format(path, k), observed = ap[k]} for k in ap if k not in fp]
    _ch = [{field = "{}[{}]".format(path, k), desired = fp[k], observed = (ap[k] if k in ap else Undefined)} for k in fp if (k not in ap or ap[k] != fp[k])]
    _rm + _ch
}

# Deep diff driven by desired (forProvider). Recurses into nested objects, but
# only descends when the observed side is also an object - an absent observed
# subtree means the cloud does not report it, which is not a committable change.
_diffField = lambda k: str, dv: any, ov: any, path: str -> [any] {
    _jsonPair = typeof(dv) == "str" and typeof(ov) == "str" and _looksJson(dv) and _looksJson(ov)
    _listPair = _scalarList(dv) and _scalarList(ov)
    _valueChanged = (not _jsonEqual(dv, ov)) if _jsonPair else ((not _sameSet(dv, ov)) if _listPair else (dv != ov))
    _leafChanged = ov != Undefined and ov != None and _valueChanged
    _leaf = [{field = path, desired = dv, observed = ov}] if _leafChanged else []
    _obj = _deepDiff(dv, ov, path) if (typeof(dv) == "dict" and typeof(ov) == "dict") else _leaf
    _mapDiff(dv or {}, ov or {}, path) if k == "tags" else _obj
}
_deepDiff = lambda desired: any, observed: any, prefix: str -> [any] {
    sum([
        _diffField(k, desired[k], (observed[k] if (typeof(observed) == "dict" and k in observed) else Undefined), (prefix + "." + k if prefix != "" else k))
        for k in desired if not _skipKey(k)
    ], [])
}

_isReconcilable = lambda field: str, reconcilable: [str] -> bool {
    any p in reconcilable { field.endswith(p) }
}

# Full change set for one composition resource (empty until it is observed).
_changesFor = lambda ocds: any, cr: str -> [any] {
    _fp = _get(ocds, cr + ".Resource.spec.forProvider", Undefined)
    _ap = _get(ocds, cr + ".Resource.status.atProvider", Undefined)
    _deepDiff(_fp, _ap, "") if (typeof(_fp) == "dict" and typeof(_ap) == "dict") else []
}

# Per-resource report entry: external name, observed flag, and the change set
# partitioned into reconcilable drift vs unreconcilable side effects.
_entry = lambda ocds: any, importResources: any, cr: str, key: str, reconcilable: [str] -> any {
    _changes = _changesFor(ocds, cr)
    {
        externalName = importResources[key]
        observed = _get(ocds, cr + ".Resource.status.atProvider", Undefined) != Undefined
        drift = [c for c in _changes if _isReconcilable(c.field, reconcilable)]
        sideEffects = [c for c in _changes if not _isReconcilable(c.field, reconcilable)]
    }
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

# Deep diff of a single resource's desired (forProvider) vs observed (atProvider).
diff = lambda desired: any, observed: any -> [Change] {
    """Deep forProvider-vs-atProvider diff -> list of Change."""
    _deepDiff(desired, observed, "")
}

managementPolicies = lambda importActive: bool, commit: bool, default: [str] -> [str] {
    """Import lifecycle -> Crossplane management policies.

    observe (importing, not committed) -> ["Observe", "LateInitialize"] (read-only to the cloud);
    commit  (importing, committed)     -> ["*"] (full management);
    otherwise (not importing)          -> the supplied default.
    """
    ["Observe", "LateInitialize"] if (importActive and not commit) else (["*"] if importActive else default)
}

buildReport = lambda config: {str:} -> {str:} {
    """Compute the import report from observed composed resources.

    config:
      ocds            observed composed resources (option("params").ocds)
      importResources {logicalKey: externalName} from spec.parameters.import.resources
      registry        {logicalKey: compositionResourceName} - the importable resources
      reconcilable    [leaf field names] backed by editable parameters (-> drift)
      requiredKeys    [logicalKey] that must all be present, else the render is blocked

    returns:
      { missing, blockRender, resources, driftCount, sideEffectCount }
    where resources[key] = { externalName, observed, drift: [Change], sideEffects: [Change] }.
    The composition wraps this into status.import (adding active/commit/phase) and
    uses blockRender to decide whether to emit managed resources.
    """
    _ocds = config.ocds
    _import = config.importResources
    _registry = config.registry
    _recon = config.reconcilable
    _required = config.requiredKeys

    _missing = [k for k in _required if k not in _import]
    _block = len(_missing) > 0
    _reportKeys = [k for k in _registry if k in _import]
    _resources = {k: _entry(_ocds, _import, _registry[k], k, _recon) for k in _reportKeys} if not _block else {}
    _driftLens = [len(_resources[k].drift) for k in _resources]
    _sideLens = [len(_resources[k].sideEffects) for k in _resources]
    {
        missing = _missing
        blockRender = _block
        resources = _resources
        driftCount = sum(_driftLens) if len(_driftLens) > 0 else 0
        sideEffectCount = sum(_sideLens) if len(_sideLens) > 0 else 0
    }
}
