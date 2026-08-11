import * as path from 'node:path';
import * as url from 'node:url';
import * as core from '@actions/core';
import * as exec from '@actions/exec';

const __dirname = path.dirname(url.fileURLToPath(import.meta.url));

const setupPs1 = path.resolve(__dirname, '../setup.ps1');
const cleanupPs1 = path.resolve(__dirname, '../cleanup.ps1');

// Only one entry point, so determine if this is the post action, and set it true
// so that the next time we're executed, it goes to the post action.
const isPost = core.getState('IsPost');
core.saveState('IsPost', true);

const connectionStringName = core.getInput('connection-string-name');
const databaseName = core.getInput('database-name');
const username = core.getInput('username');
const imageTag = core.getInput('image-tag');
const initScript = core.getInput('init-script');
const registryLoginServer = core.getInput('registry-login-server');
const registryUser = core.getInput('registry-username');
const registryPass = core.getInput('registry-password');

async function run() {
    try {
        if (!isPost) {
            console.log('Running setup action');

            const random = Math.round(10000000000 * Math.random());
            const containerName = 'setup-mysql' + random;

            core.saveState('containerName', containerName);

            console.log('containerName = ' + containerName);

            await exec.exec('pwsh', [
                '-File', setupPs1,
                '-ContainerName', containerName,
                '-ConnectionStringName', connectionStringName,
                '-DatabaseName', databaseName,
                '-Username', username,
                '-ImageTag', imageTag,
                '-InitScript', initScript,
                '-RegistryLoginServer', registryLoginServer,
                '-RegistryUser', registryUser,
                '-RegistryPass', registryPass
            ]);
        } else {
            console.log('Running cleanup');

            const containerName = core.getState('containerName');

            await exec.exec('pwsh', [
                '-File', cleanupPs1,
                '-ContainerName', containerName,
            ]);
        }
    } catch (err) {
        core.setFailed(err);
        console.log(err);
    }
}

run();
