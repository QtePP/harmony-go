/**
 * Pyodide worker for HarmonyGo.
 *
 * Python runs here, not on the page's main thread. That is the difference
 * between a timeout being recoverable and the entire WebView freezing: an
 * infinite `while True` can be stopped with `worker.terminate()` from the
 * page, whereas a main-thread run blocks navigation, timers and the bridge.
 *
 * The page owns the `dshHost` proxy; this worker only reports through
 * postMessage.
 */

importScripts('./pyodide.js');

let pyodide = null;
let loading = null;
let loadedPackages = new Set();
let pybotMounted = false;

function ensurePyodide() {
  if (pyodide) return Promise.resolve(pyodide);
  if (!loading) {
    loading = (async function () {
      var instance = await loadPyodide({ indexURL: './' });
      pyodide = instance;
      var version = instance.runPython('import sys; sys.version');
      postMessage({ type: 'ready', version: String(version) });
      return instance;
    })().catch(function (error) {
      postMessage({ type: 'fatal', error: String(error) });
      throw error;
    });
  }
  return loading;
}

self.onmessage = async function (event) {
  var data = event.data || {};
  if (data.type === 'ensure') {
    try {
      await ensurePyodide();
    } catch (_) {
      /* reported by ensurePyodide */
    }
    return;
  }
  if (data.type !== 'run') return;

  var id = String(data.id);
  var stdout = '';
  var stderr = '';
  try {
    var instance = await ensurePyodide();
    // HTTP assets are not automatically part of Pyodide's in-memory FS. The
    // pybot zip is 12MB, so mount it only when the code actually references it.
    if (!pybotMounted && String(data.code).indexOf('/pybot.zip') >= 0) {
      var response = await fetch('./pybot.zip');
      if (!response.ok) {
        throw new Error('cannot fetch pybot.zip: HTTP ' + response.status);
      }
      instance.FS.writeFile('/pybot.zip', new Uint8Array(await response.arrayBuffer()));
      pybotMounted = true;
    }
    var requested = Array.isArray(data.packages) ? data.packages : ['pandas'];
    var missing = requested.filter(function (name) { return !loadedPackages.has(name); });
    if (missing.length > 0) {
      await instance.loadPackage(missing);
      missing.forEach(function (name) { loadedPackages.add(name); });
    }
    if (Array.isArray(data.files) && data.files.length > 0) {
      try { instance.FS.mkdirTree('/workspace'); } catch (_) {}
      for (var i = 0; i < data.files.length; i++) {
        var file = data.files[i];
        var name = String(file.name || '').replace(/^.*[\\/]/, '');
        if (name.length === 0) continue;
        var binary = atob(String(file.data || ''));
        var bytes = new Uint8Array(binary.length);
        for (var b = 0; b < binary.length; b++) bytes[b] = binary.charCodeAt(b);
        instance.FS.writeFile('/workspace/' + name, bytes);
      }
    }
    instance.setStdout({ batched: function (text) { stdout += text + '\n'; } });
    instance.setStderr({ batched: function (text) { stderr += text + '\n'; } });
    var result = await instance.runPythonAsync(String(data.code));
    var value = '';
    if (result !== undefined && result !== null) {
      try { value = String(result); } catch (_) { value = '[unserializable result]'; }
    }
    postMessage({ type: 'result', id: id, ok: true, stdout: stdout, stderr: stderr, value: value });
  } catch (error) {
    postMessage({ type: 'result', id: id, ok: false, stdout: stdout, stderr: stderr, error: String(error) });
  }
};
