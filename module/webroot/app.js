(function () {
    'use strict';

    var DEFAULT_MODDIR = '/data/adb/modules/novahide';
    var seq = 0;
    var moduleDir = DEFAULT_MODDIR;

    function $(id) {
        return document.getElementById(id);
    }

    function bridge() {
        return typeof window.ksu === 'undefined' ? null : window.ksu;
    }

    function resolveModuleDir() {
        var ksu = bridge();
        if (!ksu || typeof ksu.moduleInfo !== 'function') {
            return DEFAULT_MODDIR;
        }
        try {
            var info = JSON.parse(ksu.moduleInfo());
            if (info && typeof info.moduleDir === 'string' && info.moduleDir) {
                return info.moduleDir;
            }
        } catch (err) {
            /* fall back to the documented path */
        }
        return DEFAULT_MODDIR;
    }

    function quote(value) {
        return "'" + String(value).replace(/'/g, "'\\''") + "'";
    }

    function actionCommand(args) {
        return 'sh ' + quote(moduleDir + '/action.sh') + (args ? ' ' + args : '');
    }

    function run(command, timeoutMs) {
        return new Promise(function (resolve, reject) {
            var ksu = bridge();
            if (!ksu) {
                reject(new Error('not running inside SukiSU Nova'));
                return;
            }
            var name = '__novahide_cb_' + (++seq);
            var timer = setTimeout(function () {
                delete window[name];
                reject(new Error('timed out after ' + Math.round((timeoutMs || 60000) / 1000) + 's'));
            }, timeoutMs || 60000);
            window[name] = function (code, out, err) {
                clearTimeout(timer);
                delete window[name];
                resolve({ code: Number(code), out: String(out || ''), err: String(err || '') });
            };
            try {
                ksu.exec(command, null, name);
            } catch (err) {
                clearTimeout(timer);
                delete window[name];
                reject(err);
            }
        });
    }

    function setBusy(busy) {
        ['apply', 'refresh', 'log', 'purge', 'reset'].forEach(function (id) {
            var el = $(id);
            if (el) {
                el.disabled = busy;
            }
        });
    }

    function setNotice(text) {
        var el = $('notice');
        if (!text) {
            el.hidden = true;
            el.textContent = '';
            return;
        }
        el.hidden = false;
        el.textContent = text;
    }

    function showOutput(text) {
        var el = $('output');
        if (!text) {
            el.hidden = true;
            el.textContent = '';
            return;
        }
        el.hidden = false;
        el.textContent = text;
    }

    function setVerdict(id, text) {
        var el = $(id);
        var value = el.querySelector('.value');
        value.textContent = text;
        var ready = /^ready/.test(text);
        el.classList.toggle('ok', ready);
        el.classList.toggle('warn', !ready);
    }

    function setStat(id, text) {
        $(id).textContent = text;
    }

    // The applied count is what the last apply registered, not the catalogue
    // size; a status run with no recorded apply must not claim a number.
    function hideStat(hide, mode) {
        var applied = Number(hide.applied || 0);
        var entries = Number(hide.entries || 0);
        if (!mode && !hide.recorded) {
            return 'not verified';
        }
        if (entries > 0) {
            return applied + '/' + entries + ' applied';
        }
        return applied + ' applied';
    }

    function render(data) {
        var device = data.device || {};
        var label = device.label || 'Android';
        var codename = device.codename ? ' · ' + device.codename : '';
        var model = device.model ? ' ' + device.model : '';
        $('device').textContent = label + codename + model;
        $('profile').textContent = (data.profile || '—') + (data.profileSource ? ' · ' + data.profileSource : '');

        var verdict = data.verdict || {};
        setVerdict('v-basic', verdict.basic || 'unknown');
        setVerdict('v-device', verdict.device || 'unknown');
        setVerdict('v-strong', verdict.strong || 'unknown');

        var hide = data.hide || {};
        var props = data.props || {};
        var mode = data.mode === 'apply';
        setStat('s-hidden', hideStat(hide, mode));
        setStat('s-props', mode
            ? String(props.fixed || 0) + ' fixed'
            : String(props.ok || 0) + '/' + ((props.ok || 0) + (props.failed || 0)) + ' ok');
        setStat('s-maps', String(data.maps || 0));
        setStat('s-bootconfig', String(data.bootconfig || '—'));

        var kernel = data.kernel || {};
        var susfs = data.susfs || {};
        var dl = $('kernel');
        dl.textContent = '';
        [
            ['kernel', (kernel.version || '?') + ' (uapi ' + (kernel.uapi || '?') + ')'],
            ['susfs', susfs.available
                ? (susfs.version || '?') + ' · ' + (susfs.implementation || '?') + ' · ' + (susfs.variant || '?')
                : 'unavailable'],
            ['features', data.features || '—'],
            ['zygisk', data.zygisk || '—'],
            ['banking', bankingApps(data.banking)],
            ['bank risk', bankRisk(data.banking)],
            ['log', data.log || '—']
        ].forEach(function (pair) {
            var dt = document.createElement('dt');
            dt.textContent = pair[0];
            var dd = document.createElement('dd');
            dd.textContent = pair[1];
            dl.appendChild(dt);
            dl.appendChild(dd);
        });

        var list = $('companions');
        list.textContent = '';
        (data.companions || []).forEach(function (row) {
            var li = document.createElement('li');
            var name = document.createElement('span');
            name.className = 'name';
            name.textContent = row.name;
            var state = document.createElement('span');
            state.className = 'state ' + stateClass(row.state);
            state.textContent = row.state;
            var note = document.createElement('span');
            note.className = 'note';
            note.textContent = row.note;
            li.appendChild(name);
            li.appendChild(state);
            li.appendChild(note);
            list.appendChild(li);
        });

        var conflicts = $('conflicts');
        conflicts.textContent = '';
        (data.conflicts || []).forEach(function (row) {
            var li = document.createElement('li');
            var name = document.createElement('span');
            name.className = 'name';
            name.textContent = row.name;
            var state = document.createElement('span');
            state.className = 'state ' + severityClass(row.severity);
            state.textContent = row.severity;
            var note = document.createElement('span');
            note.className = 'note';
            note.textContent = row.note;
            li.appendChild(name);
            li.appendChild(state);
            li.appendChild(note);
            conflicts.appendChild(li);
        });
        if (!(data.conflicts || []).length) {
            var none = document.createElement('li');
            var noneNote = document.createElement('span');
            noneNote.className = 'note';
            noneNote.textContent = 'no conflict detected between the installed modules';
            none.appendChild(noneNote);
            conflicts.appendChild(none);
        }
    }

    function severityClass(severity) {
        if (severity === 'high' || severity === 'medium') {
            return 'warn';
        }
        return '';
    }

    function bankingApps(banking) {
        if (!banking || !banking.apps || !banking.apps.length) {
            return 'no known Vietnamese banking app';
        }
        return banking.apps.join(', ');
    }

    // An empty risks field means two different things: the checks ran and
    // found nothing (count > 0), or they never ran because no listed bank
    // is installed (count 0). Only the first is a clean result.
    function bankRisk(banking) {
        if (!banking) {
            return 'unknown';
        }
        if (!banking.count) {
            return 'not checked: no banking app installed';
        }
        return banking.risks || "nothing beyond the app's own checks";
    }

    function stateClass(state) {
        if (state === 'present' || state === 'running') {
            return 'ok';
        }
        if (state === 'absent' || state === 'none' || state === 'disabled') {
            return 'warn';
        }
        return '';
    }

    async function refresh() {
        setBusy(true);
        try {
            var res = await run(actionCommand('json'), 45000);
            if (res.code !== 0) {
                throw new Error(res.err || ('exit ' + res.code));
            }
            var lines = res.out.trim().split('\n');
            render(JSON.parse(lines[lines.length - 1]));
            setNotice('');
        } catch (err) {
            setNotice('Could not read the module state: ' + err.message);
        } finally {
            setBusy(false);
        }
    }

    async function applyProfile() {
        var profile = $('profile-select').value;
        setBusy(true);
        setNotice('');
        try {
            var res = await run(actionCommand('apply ' + (profile || 'auto')), 120000);
            showOutput(res.out || res.err);
            if (res.code !== 0) {
                setNotice('Apply exited ' + res.code + '. See the output below.');
            }
            await refresh();
        } catch (err) {
            setNotice('Apply failed: ' + err.message);
        } finally {
            setBusy(false);
        }
    }

    async function showLog() {
        setBusy(true);
        try {
            var res = await run(actionCommand('log 120'), 45000);
            showOutput(res.out || res.err || 'no log yet');
        } catch (err) {
            setNotice('Could not read the log: ' + err.message);
        } finally {
            setBusy(false);
        }
    }

    async function purgeTraces() {
        setBusy(true);
        try {
            var res = await run(actionCommand('purge'), 45000);
            showOutput(res.out || res.err);
            await refresh();
        } catch (err) {
            setNotice('Purge failed: ' + err.message);
        } finally {
            setBusy(false);
        }
    }

    async function resetConfig() {
        setBusy(true);
        try {
            var res = await run(actionCommand('reset'), 45000);
            showOutput(res.out || res.err);
            await refresh();
        } catch (err) {
            setNotice('Reset failed: ' + err.message);
        } finally {
            setBusy(false);
        }
    }

    function init() {
        moduleDir = resolveModuleDir();
        $('apply').addEventListener('click', applyProfile);
        $('refresh').addEventListener('click', refresh);
        $('log').addEventListener('click', showLog);
        $('purge').addEventListener('click', purgeTraces);
        $('reset').addEventListener('click', resetConfig);

        if (!bridge()) {
            setNotice('Open this page from NovaHide in SukiSU Nova: the module action or the module WebUI.');
            $('hint').textContent = 'The WebUI talks to the device through the manager, so it needs the app.';
            return;
        }
        refresh();
    }

    init();
}());
