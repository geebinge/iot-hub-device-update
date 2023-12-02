/**
 * @file eg_mqtt_broker_client.c
 * @brief Implement the Event Grid MQTT Broker client helper functions
 *
 * @copyright Copyright (c) Microsoft Corporation.
 * Licensed under the MIT License.
 */
#include "aduc/eg_mqtt_broker_client.h"
#include "aduc/config_utils.h"
#include "aduc/logging.h"
#include "du_agent_sdk/mqtt_client_settings.h" // for ADUC_MQTT_SETTINGS
#include "aduc/string_c_utils.h" // ADUC_StringFormat
#include "aducpal/stdlib.h" // memset

/**
 * @brief Free resources allocated the MQTT broker settings
 */
void FreeMqttBrokerSettings(ADUC_MQTT_SETTINGS* settings)
{
    if (settings == NULL)
    {
        return;
    }

    free(settings->hostname);
    free(settings->clientId);
    free(settings->username);
    free(settings->caFile);
    free(settings->certFile);
    free(settings->keyFile);
    memset(settings, 0, sizeof(*settings));
}

/**
 * @brief Reads MQTT broker connection settings from the configuration file.
 *
 * This function reads the MQTT client settings for communicating with the Azure Device Update service
 * from the configuration file. The settings are read from the `agent.connectionData.mqttBroker` section
 * of the configuration file.
 *
 * @param settings A pointer to an `ADUC_MQTT_SETTINGS` structure to populate with the MQTT broker settings.
 *
 * @return Returns `true` if the settings were successfully read and populated, otherwise `false`.
 *
 * @remark The caller is responsible for freeing the returned settings by calling `FreeMqttBrokerSettings` function.
 */
bool ReadMqttBrokerSettings(ADUC_MQTT_SETTINGS* settings)
{
    bool result = false;
    const ADUC_ConfigInfo* config = NULL;
    const ADUC_AgentInfo* agent_info = NULL;
    int tmp = -1;

    if (settings == NULL)
    {
        goto done;
    }

    memset(settings, 0, sizeof(*settings));

    config = ADUC_ConfigInfo_GetInstance();
    if (config == NULL)
    {
        goto done;
    }

    agent_info = ADUC_ConfigInfo_GetAgent(config, 0);

    if (strcmp(agent_info->connectionType, ADUC_CONNECTION_TYPE_ADPS2_MQTT) == 0)
    {
        settings->hostnameSource = ADUC_MQTT_HOSTNAME_SOURCE_DPS;
    }
    else if (strcmp(agent_info->connectionType, ADUC_CONNECTION_TYPE_MQTTBROKER) == 0)
    {
        settings->hostnameSource = ADUC_MQTT_HOSTNAME_SOURCE_CONFIG_FILE;
    }
    else
    {
        Log_Error("Invalid connection type: %s", agent_info->connectionType);
        goto done;
    }

    // Read the x.506 certificate authentication data.
    if (!ADUC_AgentInfo_ConnectionData_GetStringField(agent_info, "mqttBroker.caFile", &settings->caFile))
    {
        settings->caFile = NULL;
    }

    if (!ADUC_AgentInfo_ConnectionData_GetStringField(agent_info, "mqttBroker.certFile", &settings->certFile))
    {
        settings->certFile = NULL;
    }

    if (!ADUC_AgentInfo_ConnectionData_GetStringField(agent_info, "mqttBroker.keyFile", &settings->keyFile))
    {
        settings->keyFile = NULL;
    }

    if (IsNullOrEmpty(settings->username))
    {
        if (!ADUC_AgentInfo_ConnectionData_GetStringField(agent_info, "mqttBroker.username", &settings->username))
        {
            settings->username = NULL;
            Log_Error("Username field is not specified");
            goto done;
        }
    }

    if (settings->hostnameSource == ADUC_MQTT_HOSTNAME_SOURCE_DPS)
    {
        Log_Info("Using DPS module to retrieve MQTT broker endpoint data");
    }
    else if (settings->hostnameSource == ADUC_MQTT_HOSTNAME_SOURCE_CONFIG_FILE)
    {
        // Expecting MQTT hostname to be specified in the config file.
        if (!ADUC_AgentInfo_ConnectionData_GetStringField(agent_info, "mqttBroker.hostname", &settings->hostname))
        {
            Log_Error("MQTT Broker hostname is not specified");
        }
    }

    // Common MQTT connection data fields.
    if (!ADUC_AgentInfo_ConnectionData_GetIntegerField(
            agent_info, "mqttBroker.mqttVersion", &tmp) || tmp < MIN_BROKER_MQTT_VERSION)
    {
        Log_Info("Using default MQTT protocol version: %d", DEFAULT_MQTT_BROKER_PROTOCOL_VERSION);
        settings->mqttVersion = DEFAULT_MQTT_BROKER_PROTOCOL_VERSION;
    }
    else
    {
        settings->mqttVersion = tmp;
    }

    if (!ADUC_AgentInfo_ConnectionData_GetUnsignedIntegerField(agent_info, "mqttBroker.tcpPort", &settings->tcpPort))
    {
        Log_Info("Using default TCP port: %d", DEFAULT_TCP_PORT);
        settings->tcpPort = DEFAULT_TCP_PORT;
    }

    if (!ADUC_AgentInfo_ConnectionData_GetBooleanField(agent_info, "mqttBroker.useTLS", &settings->useTLS))
    {
        Log_Info("UseTLS: %d", DEFAULT_USE_TLS);
        settings->useTLS = DEFAULT_USE_TLS;
    }

    if (!ADUC_AgentInfo_ConnectionData_GetIntegerField(agent_info, "mqttBroker.qos", &tmp) || tmp < 0 || tmp > 2)
    {
        Log_Info("QoS: %d", DEFAULT_QOS);
        settings->qos = DEFAULT_QOS;
    }
    else
    {
        settings->qos = tmp;
    }

    if (!ADUC_AgentInfo_ConnectionData_GetBooleanField(agent_info, "mqttBroker.cleanSession", &settings->cleanSession))
    {
        Log_Info("CleanSession: %d", DEFAULT_ADPS_CLEAN_SESSION);
        settings->cleanSession = DEFAULT_ADPS_CLEAN_SESSION;
    }

    if (!ADUC_AgentInfo_ConnectionData_GetUnsignedIntegerField(
            agent_info, "mqttBroker.keepAliveInSeconds", &settings->keepAliveInSeconds))
    {
        Log_Info("Keep alive: %d sec.", DEFAULT_KEEP_ALIVE_IN_SECONDS);
        settings->keepAliveInSeconds = DEFAULT_KEEP_ALIVE_IN_SECONDS;
    }

    result = true;

done:
    ADUC_ConfigInfo_ReleaseInstance(config);
    if (!result)
    {
        FreeMqttBrokerSettings(settings);
    }
    return result;
}