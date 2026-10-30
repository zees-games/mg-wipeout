extends RefCounted

## Where this game's own files are, wherever this copy lives. A delivered pack mounts at
## `res://dot_cloud/<id>/<version>/`, so an absolute `res://` path to its OWN files resolves against the HOST project.
## Hold paths in a `static var`, not a `const`: `load(WoPaths.rebase("res://props/wo_crate.tscn"))`.

const _SELF := preload("wo_paths.gd")


## This game's content root: `res://` built in, the mount prefix delivered.
static func root() -> String:
	# Through [Resource], because a const-preloaded script is typed as its own class and
	# `resource_path` is not reachable on that — "Cannot find member resource_path in
	# base res://…". The cast costs nothing and is the only spelling that compiles.
	var here: Resource = _SELF
	return here.resource_path.get_base_dir().get_base_dir()


## Moves one `res://` path onto [method root]. Anything else comes back untouched, so it is safe around a value that
## may already be absolute or `user://`. Format specifiers survive: only the prefix is replaced.
static func rebase(path: String) -> String:
	return rebase_onto(path, root())


## [method rebase], against a root given rather than discovered, so the mounted case can be TESTED from a build: built
## in, [method root] is `res://` and every property that matters only in a pack is a tautology (breaking idempotence
## still passed 101 checks). This is the only spelling that gives the suite a real mount prefix.
static func rebase_onto(path: String, here: String) -> String:
	if not path.begins_with("res://"):
		return path

	# Idempotent: the publisher rewrites `res://` in `.tscn`, `.tres` and `.import` but not `.gd`, so a game holds
	# both kinds, and rebasing a rebased path doubles the prefix. See ../dot-server-deploy/docs/delivery-
	# constraint.md. Built in, this returns its argument.
	if path.begins_with(here):
		return path

	return here.path_join(path.substr(6))
