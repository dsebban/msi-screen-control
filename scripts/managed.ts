// Use the user's installed OMP broker so long jobs stay visible in `omp ps`.
import { homedir } from "node:os";
import { resolve } from "node:path";

const root = resolve(import.meta.dir, "..");
const modulePath = process.env.OMP_LAUNCH_CLIENT ??
    `${homedir()}/.bun/install/global/node_modules/@oh-my-pi/pi-coding-agent/src/launch/client.ts`;
const { daemonClientForProject, closeDaemonClients } = await import(modulePath);
const client = await daemonClientForProject(root);
try {
    const verify = process.argv[2] === "--verify";
    const name = verify ? `msi-screen-verify-${Date.now()}` : "msi-screen-menu";
    const result = await client.request({
        op: "start", owner: "msi-screen-control",
        spec: {
            name, application: "/bin/bash",
            args: ["script/build_and_run.sh", verify ? "--managed-verify" : "--managed-run"],
            env: {}, cwd: root, pty: false, restart: "no", persist: true, detached: false
        }
    });
    console.log(JSON.stringify(result));
    console.log(`Logs: omp ps logs ${name} --dir ${root}`);
} finally {
    closeDaemonClients();
}
