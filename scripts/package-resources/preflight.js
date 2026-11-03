// Installer JavaScript only. No external commands are permitted by Distribution.
function freshInstall() {
    var app = '/Library/Application Support/InsomniaSafeLocal';
    var recovery = '/Library/Application Support/InsomniaLocalPower';
    if (system.files.fileExistsAtPath(app) || system.files.fileExistsAtPath(recovery)) {
        my.result.type = 'Fatal';
        my.result.message = 'Ya existe una instalación o recuperación pendiente. Restaura y retira primero la versión anterior; no se sobrescribirá.';
        return false;
    }
    return true;
}

// An update is a separate package and requires recovery-first preparation
// by the currently installed app. That operation quits the GUI, restores
// journals, retires the daemon, removes its empty root store and unregisters.
// A running or merely disabled daemon leaves that store in place and blocks
// this update. Installer also requires every copy of this app to be closed.
function preparedUpdate() {
    var app = '/Library/Application Support/InsomniaSafeLocal';
    var recovery = '/Library/Application Support/InsomniaLocalPower';
    if (!system.files.fileExistsAtPath(app) || system.files.fileExistsAtPath(recovery)) {
        my.result.type = 'Fatal';
        my.result.message = 'La actualización necesita preparar la aplicación anterior y completar su recuperación antes de continuar. No se sobrescribirá una sesión pendiente.';
        return false;
    }
    return true;
}
