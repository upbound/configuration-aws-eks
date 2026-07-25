package main

// Brownfield import kit — Go port of functions/eks/importkit.k.
//
// A generic, provider-agnostic engine for adopting pre-existing cloud resources
// into a Crossplane v2 composition. It works purely on observed composed
// resources: each resource's spec.forProvider is treated as the composition's
// desired state (source of truth) and status.atProvider as live cloud state. It
// carries no provider-schema dependency and can be reused by any composition.
//
// Dynamic KCL dicts/values are modeled as map[string]any / []any / scalars,
// since forProvider/atProvider are read from unstructured observed resources.

import (
	"encoding/json"
	"fmt"
	"reflect"
	"regexp"
	"sort"
	"strings"
)

// undefined is a sentinel mirroring KCL's Undefined (an absent key), distinct
// from a nil value (KCL None).
var undefined = &struct{ name string }{name: "undefined"}

// Change is a single field-level difference between desired (forProvider) and
// live (atProvider) state.
//
// KCL schema Change = {field: str, desired?: any, observed?: any}. The optional
// fields are modeled with presence booleans so the eventual status output can
// distinguish an addition (desired only), a removal (observed only), and a
// change (both) exactly as KCL does.
type Change struct {
	Field       string
	Desired     any
	HasDesired  bool
	Observed    any
	HasObserved bool
}

// MarshalJSON emits {field, desired?, observed?} — absent fields are omitted,
// matching KCL's Change schema so the status shape is structurally identical.
func (c Change) MarshalJSON() ([]byte, error) {
	m := map[string]any{"field": c.Field}
	if c.HasDesired {
		m["desired"] = c.Desired
	}
	if c.HasObserved {
		m["observed"] = c.Observed
	}
	return json.Marshal(m)
}

// Entry is the per-resource report entry (KCL _entry return shape).
type Entry struct {
	ExternalName any      `json:"externalName"`
	Observed     bool     `json:"observed"`
	Drift        []Change `json:"drift"`
	SideEffects  []Change `json:"sideEffects"`
}

// Report is the buildReport result (KCL buildReport return shape).
type Report struct {
	Missing         []string         `json:"missing"`
	BlockRender     bool             `json:"blockRender"`
	Resources       map[string]Entry `json:"resources"`
	DriftCount      int              `json:"driftCount"`
	SideEffectCount int              `json:"sideEffectCount"`
}

// ReportConfig mirrors the KCL buildReport `config` dict.
type ReportConfig struct {
	OCDS            any               // observed composed resources
	ImportResources map[string]any    // {logicalKey: externalName}
	Registry        map[string]string // {logicalKey: compositionResourceName}
	Reconcilable    []string          // leaf field-name suffixes backed by editable params
	RequiredKeys    []string          // logical keys that must all be present
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

// get is a dot-separated path getter with default (KCL _get). Splits on ".".
func get(x any, path string, def any) any {
	cur := x
	for _, p := range strings.Split(path, ".") {
		m, ok := cur.(map[string]any)
		if !ok {
			return def
		}
		v, ok := m[p]
		if !ok {
			return def
		}
		cur = v
	}
	return cur
}

// isScalar mirrors KCL _isScalar: typeof in [str, int, float, bool].
func isScalar(v any) bool {
	switch v.(type) {
	case string, bool, int, int8, int16, int32, int64,
		uint, uint8, uint16, uint32, uint64, float32, float64:
		return true
	}
	return false
}

// scalarList mirrors KCL _scalarList: a list whose every element is scalar. An
// empty list qualifies (KCL all() over an empty list is true).
func scalarList(v any) bool {
	l, ok := v.([]any)
	if !ok {
		return false
	}
	for _, e := range l {
		if !isScalar(e) {
			return false
		}
	}
	return true
}

func toFloat(v any) (float64, bool) {
	switch n := v.(type) {
	case int:
		return float64(n), true
	case int8:
		return float64(n), true
	case int16:
		return float64(n), true
	case int32:
		return float64(n), true
	case int64:
		return float64(n), true
	case uint:
		return float64(n), true
	case uint8:
		return float64(n), true
	case uint16:
		return float64(n), true
	case uint32:
		return float64(n), true
	case uint64:
		return float64(n), true
	case float32:
		return float64(n), true
	case float64:
		return n, true
	}
	return 0, false
}

// scalarEqual compares two scalars. Numbers compare by numeric value (so
// int(1) == float64(1), as in KCL); other scalars compare directly.
func scalarEqual(a, b any) bool {
	if af, ok := toFloat(a); ok {
		if bf, ok2 := toFloat(b); ok2 {
			return af == bf
		}
		return false
	}
	if _, ok := toFloat(b); ok {
		return false
	}
	return a == b
}

// containsScalar reports whether b contains e (scalar membership, KCL `e in b`).
func containsScalar(b []any, e any) bool {
	for _, x := range b {
		if scalarEqual(x, e) {
			return true
		}
	}
	return false
}

// sameSet mirrors KCL _sameSet EXACTLY:
//
//	len(a) == len(b) and (all e in a { e in b }) and (all e in b { e in a })
//
// This is length-equality plus mutual set-membership, NOT a multiset compare:
// e.g. ["a","a","b"] and ["a","b","b"] are reported EQUAL (same length, each
// element of one is a member of the other), even though their multisets differ.
func sameSet(a, b any) bool {
	la, oka := a.([]any)
	lb, okb := b.([]any)
	if !oka || !okb {
		return false
	}
	if len(la) != len(lb) {
		return false
	}
	for _, e := range la {
		if !containsScalar(lb, e) {
			return false
		}
	}
	for _, e := range lb {
		if !containsScalar(la, e) {
			return false
		}
	}
	return true
}

// jsonObjRe replicates the KCL _looksJson pattern EXACTLY: a string opens like a
// JSON object — optional whitespace, "{", optional whitespace, then '"' or '}'.
// This rejects Go templates ("{{ ... }}") and "["-arrays.
var jsonObjRe = regexp.MustCompile(`^\s*\{\s*("|\})`)

// looksJson mirrors KCL _looksJson.
func looksJson(s string) bool {
	return jsonObjRe.MatchString(s)
}

// jsonEqual mirrors KCL _jsonEqual: json.decode(a) == json.decode(b), i.e.
// semantic (whitespace/key-order insensitive) equality. Only ever called on
// strings that passed looksJson. A decode error is treated as "not equal"
// (KCL would crash; see RISK note) rather than panicking.
func jsonEqual(a, b string) bool {
	var av, bv any
	if err := json.Unmarshal([]byte(a), &av); err != nil {
		return false
	}
	if err := json.Unmarshal([]byte(b), &bv); err != nil {
		return false
	}
	return reflect.DeepEqual(av, bv)
}

// skipKey mirrors KCL _skipKey: keys ending in Ref/Refs/Selector, or "tagsAll".
func skipKey(k string) bool {
	return strings.HasSuffix(k, "Ref") ||
		strings.HasSuffix(k, "Refs") ||
		strings.HasSuffix(k, "Selector") ||
		k == "tagsAll"
}

// asMap coerces a value to map[string]any, returning an empty map for anything
// else (mirrors KCL `x or {}`).
func asMap(v any) map[string]any {
	if m, ok := v.(map[string]any); ok {
		return m
	}
	return map[string]any{}
}

func sortedKeys(m map[string]any) []string {
	ks := make([]string, 0, len(m))
	for k := range m {
		ks = append(ks, k)
	}
	sort.Strings(ks)
	return ks
}

// looseEqual mirrors KCL value equality (`!=`): numeric-aware for scalars,
// structural otherwise.
func looseEqual(a, b any) bool {
	if isScalar(a) && isScalar(b) {
		return scalarEqual(a, b)
	}
	return reflect.DeepEqual(a, b)
}

// mapDiff is the bidirectional diff for open-keyed maps (tags), KCL _mapDiff:
//   - removals: keys in ap (observed) but not fp (desired) -> observed only.
//   - additions/changes: keys in fp where absent-in-ap OR changed -> desired
//     (+ observed when present).
//
// Removals are emitted before additions/changes, matching KCL `_rm + _ch`.
// Field path is "path[key]".
func mapDiff(fpv, apv any, path string) []Change {
	fp := asMap(fpv)
	ap := asMap(apv)
	var out []Change
	// removals
	for _, k := range sortedKeys(ap) {
		if _, inFp := fp[k]; !inFp {
			out = append(out, Change{
				Field:       fmt.Sprintf("%s[%s]", path, k),
				Observed:    ap[k],
				HasObserved: true,
			})
		}
	}
	// additions / changes
	for _, k := range sortedKeys(fp) {
		av, inAp := ap[k]
		if !inAp || !looseEqual(av, fp[k]) {
			c := Change{
				Field:      fmt.Sprintf("%s[%s]", path, k),
				Desired:    fp[k],
				HasDesired: true,
			}
			if inAp {
				c.Observed = av
				c.HasObserved = true
			}
			out = append(out, c)
		}
	}
	return out
}

// valueChanged mirrors KCL _valueChanged branching ORDER:
//  1. both JSON-looking strings   -> !jsonEqual
//  2. else both scalar lists      -> !sameSet
//  3. else                        -> dv != ov
//
// json is only decoded on the JSON-string branch (KCL never decodes a
// non-JSON-looking string).
func valueChanged(dv, ov any) bool {
	ds, dIsStr := dv.(string)
	os, oIsStr := ov.(string)
	if dIsStr && oIsStr && looksJson(ds) && looksJson(os) {
		return !jsonEqual(ds, os)
	}
	if scalarList(dv) && scalarList(ov) {
		return !sameSet(dv, ov)
	}
	return !looseEqual(dv, ov)
}

// diffField mirrors KCL _diffField dispatch. Branch ORDER (as the KCL evaluates
// to a final value):
//   - k == "tags"          -> mapDiff (overrides everything else)
//   - both dicts           -> deepDiff (recurse)
//   - else leaf            -> a single Change iff observed is present (not
//     Undefined) and not None and the value changed.
//
// ovPresent==false models KCL Undefined (key absent in observed); ov==nil with
// ovPresent==true models KCL None.
func diffField(k string, dv, ov any, ovPresent bool, path string) []Change {
	if k == "tags" {
		return mapDiff(dv, ov, path)
	}
	dvMap, dvIsMap := dv.(map[string]any)
	ovMap, ovIsMap := ov.(map[string]any)
	if dvIsMap && ovIsMap {
		return deepDiff(dvMap, ovMap, path)
	}
	leafChanged := ovPresent && ov != nil && valueChanged(dv, ov)
	if leafChanged {
		return []Change{{
			Field:       path,
			Desired:     dv,
			HasDesired:  true,
			Observed:    ov,
			HasObserved: true,
		}}
	}
	return nil
}

// deepDiff recurses over desired keys (KCL _deepDiff), skipping _skipKey and
// flattening per-field change lists. Only descends when the observed side is a
// dict that also has the key; an absent observed subtree yields no change.
func deepDiff(desired, observed map[string]any, prefix string) []Change {
	if desired == nil {
		return nil
	}
	var out []Change
	for _, k := range sortedKeys(desired) {
		if skipKey(k) {
			continue
		}
		var ov any
		ovPresent := false
		if observed != nil {
			if v, ok := observed[k]; ok {
				ov = v
				ovPresent = true
			}
		}
		path := k
		if prefix != "" {
			path = prefix + "." + k
		}
		out = append(out, diffField(k, desired[k], ov, ovPresent, path)...)
	}
	return out
}

// isReconcilable mirrors KCL _isReconcilable: field ends with any suffix in the
// reconcilable list.
func isReconcilable(field string, reconcilable []string) bool {
	for _, p := range reconcilable {
		if strings.HasSuffix(field, p) {
			return true
		}
	}
	return false
}

// changesFor is the full change set for one composition resource (KCL
// _changesFor): diff of its forProvider vs atProvider. Empty until observed.
func changesFor(ocds any, cr string) []Change {
	fp := get(ocds, cr+".Resource.spec.forProvider", nil)
	ap := get(ocds, cr+".Resource.status.atProvider", nil)
	fpm, fok := fp.(map[string]any)
	apm, aok := ap.(map[string]any)
	if fok && aok {
		return deepDiff(fpm, apm, "")
	}
	return nil
}

// entry is the per-resource report entry (KCL _entry): external name, observed
// flag, and the change set partitioned into reconcilable drift vs side effects.
func entry(ocds any, importResources map[string]any, cr, key string, reconcilable []string) Entry {
	changes := changesFor(ocds, cr)
	drift := []Change{}
	side := []Change{}
	for _, c := range changes {
		if isReconcilable(c.Field, reconcilable) {
			drift = append(drift, c)
		} else {
			side = append(side, c)
		}
	}
	ap := get(ocds, cr+".Resource.status.atProvider", undefined)
	return Entry{
		ExternalName: importResources[key],
		Observed:     ap != undefined,
		Drift:        drift,
		SideEffects:  side,
	}
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

// diff is a deep forProvider-vs-atProvider diff of a single resource -> []Change
// (KCL public `diff`).
func diff(desired, observed any) []Change {
	dm, _ := desired.(map[string]any)
	om, _ := observed.(map[string]any)
	return deepDiff(dm, om, "")
}

// managementPolicies maps import lifecycle -> Crossplane management policies
// (KCL public `managementPolicies`):
//
//	importing & not committed -> ["Observe", "LateInitialize"]
//	importing & committed     -> ["*"]
//	not importing             -> the supplied default.
func managementPolicies(importActive, commit bool, def []string) []string {
	if importActive && !commit {
		return []string{"Observe", "LateInitialize"}
	}
	if importActive {
		return []string{"*"}
	}
	return def
}

// buildReport computes the import report from observed composed resources (KCL
// public `buildReport`).
func buildReport(cfg ReportConfig) Report {
	missing := []string{}
	for _, k := range cfg.RequiredKeys {
		if _, ok := cfg.ImportResources[k]; !ok {
			missing = append(missing, k)
		}
	}
	block := len(missing) > 0

	resources := map[string]Entry{}
	if !block {
		for k, cr := range cfg.Registry {
			if _, ok := cfg.ImportResources[k]; ok {
				resources[k] = entry(cfg.OCDS, cfg.ImportResources, cr, k, cfg.Reconcilable)
			}
		}
	}

	driftCount, sideCount := 0, 0
	for _, e := range resources {
		driftCount += len(e.Drift)
		sideCount += len(e.SideEffects)
	}

	return Report{
		Missing:         missing,
		BlockRender:     block,
		Resources:       resources,
		DriftCount:      driftCount,
		SideEffectCount: sideCount,
	}
}
