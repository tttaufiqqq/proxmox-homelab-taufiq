# `app-server`: Laravel couldn't write its own log file, and it took the whole app down with it

**Date:** 2026-07-20
**Goal:** Two unrelated-looking pages on `Animal-Shelter-Workshop` broke within the same session —
booking confirmation (`/bookings/238/confirm`, 500) and the animal-matching modal
(`/animal-matches`, "Something went wrong"). Same day as the
[`reporting`/`booking` split](../13-mariadb-reporting-booking-split/mariadb-reporting-booking-split.md),
so the first assumption was a DB connection regression from that work. It wasn't.

## Symptom

`/bookings/238/confirm` (PATCH, confirming a booking with `agree_terms` + `animal_ids`) returned a
500 with `UnexpectedValueException` as the page title. `/animal-matches` didn't 500 outright, but
the "Your Perfect Matches" modal rendered its own error card instead of match results.

Both error bodies were a wall of the *same line* repeated dozens of times:

```
The stream or file "/home/taufiq/Animal-Shelter-Workshop/storage/logs/laravel-2026-07-20.log"
could not be opened in append mode: Failed to open stream: Permission denied
```

Neither page told me anything about *why* booking confirmation or match calculation actually
failed — because whatever the real error was, Laravel never got to show it. It died trying to
write the error to the log, then died again trying to log *that* failure.

## Pulling the logs

```bash
ssh taufiq@100.100.123.90
tail -100 /home/taufiq/Animal-Shelter-Workshop/storage/logs/laravel-2026-07-20.log
```

Confirmed the same permission-denied text was already sitting in the log itself, which meant it
wasn't just a one-off render glitch — every single log write since some point today was failing,
web request or not.

## Diagnosis

First check: who owns the file, and does the group actually match the web server's user.

```bash
ls -la /home/taufiq/Animal-Shelter-Workshop/storage/logs/
stat -c '%U %G %a' /home/taufiq/Animal-Shelter-Workshop/storage/logs/laravel-2026-07-20.log
```

```
-rw-rw-r-- 1 taufiq taufiq  16126 Jul 20 01:41 laravel-2026-07-20.log
-rwxrwxr-x 1 taufiq www-data 812186 Jul 20 01:15 laravel.log
```

`laravel.log` (the un-dated symlink/backup Monolog also writes) is owned `taufiq:www-data`, which
is correct — group has write, and the app runs as `www-data`. But today's dated file,
`laravel-2026-07-20.log`, is owned `taufiq:taufiq`. Mode `664` means group gets read+write, but
`www-data` isn't in that group, so it falls into "other" — read-only. That's the whole bug: one
file, wrong group.

Confirmed the app actually runs as `www-data`, not `taufiq`:

```bash
ps aux | grep -E 'php-fpm|nginx' | grep -v grep
id www-data
```

```
www-data   24353  ...  php-fpm: pool www
www-data   24354  ...  php-fpm: pool www
uid=33(www-data) gid=33(www-data) groups=33(www-data)
```

`www-data`'s only group is `www-data` (33) — it's not in `taufiq`'s group, so it had zero write
access to a file owned `taufiq:taufiq`.

**Why did this one file end up with the wrong group when every previous day's log didn't?**
`storage/logs/` is owned `taufiq:www-data`, but without the setgid bit, a newly created file
inherits the *creating process's* primary group, not the directory's group. Every other log file
got created by `php-fpm` (running as `www-data`), so its group came out right by accident. Today's
file was born at 17:34 — well before `.provisioned`'s 23:33 timestamp — which lines up with the
DB-split work: I was running `php artisan` commands directly over SSH as `taufiq` while testing
the new connections (`config:get`, a couple of `tinker` sessions — both show up as unrelated
`ERROR` lines earlier in the same log). The first artisan command that touched logging that day
created the dated file under `taufiq`'s primary group instead of `www-data`, and every write after
that — from the web app itself — hit permission denied.

## The mess of repeated text, explained

The reason the error page was 80 lines of the identical sentence instead of one clean message:
Monolog's own write failure raises an exception. Laravel's exception handler catches it and tries
to *log the exception* — which is itself another `Log::` call, which fails again, wrapped around
the previous failure. That repeats until PHP's exception-chaining bottoms out. On the
`/animal-matches` side you can see the app's own instrumentation caught in the same loop —
`Starting match calculation` → fails to log → caught and logged as `Match calculation error` →
fails to log → caught by the outer timeout wrapper and logged as `Request timeout` → fails to log.
None of that is the real bug in match calculation; it's the same permission error being re-thrown
and re-caught at every layer that tries to log something.

## Fix

Immediate fix — get the existing file back to a writable group:

```bash
sudo chgrp www-data /home/taufiq/Animal-Shelter-Workshop/storage/logs/laravel-2026-07-20.log
sudo chmod g+w /home/taufiq/Animal-Shelter-Workshop/storage/logs/laravel-2026-07-20.log
```

Root-cause fix — force every *future* file created under `storage/` and `bootstrap/cache` to
inherit the `www-data` group no matter which user creates it, by setting the setgid bit on the
directories:

```bash
sudo find /home/taufiq/Animal-Shelter-Workshop/storage \
          /home/taufiq/Animal-Shelter-Workshop/bootstrap/cache \
          -type d -exec chmod g+s {} \;
```

Verified `www-data` can actually write now, without waiting for a real request:

```bash
sudo -u www-data bash -c 'echo test >> /home/taufiq/Animal-Shelter-Workshop/storage/logs/laravel-2026-07-20.log && echo WRITE_OK'
```

```
WRITE_OK
```

(removed the test line after confirming)

## Making it stick past the next deploy

The deploy playbook (`infrastructure/ansible/playbooks/app-server.yml`) already chowns the whole
app directory to `taufiq:www-data` and sets `storage`/`bootstrap/cache` to `0775` on every run —
but never set setgid, so the fix above would only have lasted until the next time I ran an artisan
command by hand between deploys. Added a task right after the existing permissions step:

```yaml
- name: Force www-data group inheritance on storage and cache (setgid)
  shell: find {{ item }} -type d -exec chmod g+s {} \;
  loop:
    - /home/taufiq/Animal-Shelter-Workshop/storage
    - /home/taufiq/Animal-Shelter-Workshop/bootstrap/cache
  changed_when: false
```

Now every deploy re-asserts setgid the same way it already re-asserts ownership and mode, so a
future manual `artisan` run over SSH can't quietly break logging for the rest of the day again.

## Why CI never caught this

First question once the fix was in: the workflow (`docs/11-ci.md`) runs on every push, so why did
it not flag this? Because it structurally can't reach it. `tests.yml` runs on `linux-gh-runner`, a
completely separate CT, against a fresh checkout, with one user (the runner account) doing
everything — there's no second user in the picture, so the "manual SSH command as `taufiq` vs.
web server as `www-data`" group mismatch that caused this never exists in CI's execution model.
More basically: CI never touches `app-server` at all — there's no CD step, `app-server.yml` gets
run by hand. This was host filesystem state drift on a specific long-lived machine, not an
application bug, so no `Unit`/`Feature`/`Browser` test could have expressed it in the first place.

What *is* a real gap: `app-server.yml` had no check that its own permissions tasks actually worked
— a regression there would only ever surface as a live 500. Added one more task, right after the
setgid task, that fails the deploy loudly if `www-data` can't write to `storage/logs`:

```yaml
- name: Verify www-data can write to storage/logs
  become_user: www-data
  shell: |
    set -e
    marker=/home/taufiq/Animal-Shelter-Workshop/storage/logs/.deploy-write-check
    echo "deploy write check $(date -Iseconds)" >> "$marker"
    rm -f "$marker"
  changed_when: false
```

Confirmed the exact command works as `www-data` before adding it:

```bash
sudo -u www-data bash -c 'echo test >> storage/logs/.deploy-write-check && rm -f storage/logs/.deploy-write-check && echo VERIFY_OK'
```

```
VERIFY_OK
```

## Current State

| Item | Before | After |
|---|---|---|
| `storage/logs/laravel-2026-07-20.log` group | `taufiq` | `www-data` |
| `storage/`, `bootstrap/cache/` setgid bit | not set | set (`g+s`, applies recursively going forward) |
| `app-server.yml` | chown + `0775` only | chown + `0775` + setgid task + write-check assertion |

Booking confirmation and animal-matching both need retesting now that logging actually works —
if either still fails, the real exception will show up cleanly in
`storage/logs/laravel-2026-07-20.log` instead of behind this wall of permission-denied noise.
