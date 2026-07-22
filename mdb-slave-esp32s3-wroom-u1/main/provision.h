/*
 * VMflow.xyz
 *
 * provision.h — One-time device claim task
 *
 * Forward declaration for provision_claim_task, defined in
 * mdb-slave-esp32s3.c. The captive portal claim handler in
 * webui_server.c spawns this task after persisting prov_code +
 * srv_url to NVS.
 *
 * The task itself reads from NVS, POSTs to {srv_url}/functions/v1/claim-device,
 * persists company_id/device_id/passkey/mqtt_host/mqtt_port on success,
 * erases prov_code, and reboots so steady-state startup takes over.
 */

#ifndef PROVISION_H
#define PROVISION_H

void provision_claim_task(void *arg);

#endif /* PROVISION_H */
