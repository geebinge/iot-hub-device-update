/**
 * @file adu_enrollment_management.c
 * @brief Implementation for device enrollment status management.
 *
 * @copyright Copyright (c) Microsoft Corporation.
 * Licensed under the MIT License.
 */

#include "aduc/adu_enrollment_management.h"

#include <aduc/adu_communication_channel.h>
#include <aduc/adu_enrollment.h>
#include <aduc/adu_enrollment_utils.h>
#include <aduc/adu_mosquitto_utils.h>
#include <aduc/adu_mqtt_common.h>
#include <aduc/adu_mqtt_protocol.h>
#include <aduc/adu_types.h>
#include <aduc/agent_module_interface_internal.h>
#include <aduc/agent_state_store.h>
#include <aduc/config_utils.h>
#include <aduc/enrollment_request_operation.h>
#include <aduc/logging.h>
#include <aduc/retry_utils.h> // ADUC_GetTimeSinceEpochInSeconds
#include <aduc/string_c_utils.h> // IsNullOrEmpty
#include <aduc/topic_mgmt_lifecycle.h> // TopicMgmtLifecycle_UninitRetriableOperationContext
#include <aducpal/time.h> // time_t

#include <parson.h> // JSON_Value, JSON_Object
#include <parson_json_utils.h> // ADUC_JSON_Get*

#include <mosquitto.h> // mosquitto related functions
#include <mqtt_protocol.h>
#include <string.h>

// keep this last to avoid interfering with system headers
#include <aduc/aduc_banned.h>

/////////////////////////////////////////////////////////////////////////////
//
// BEGIN - ADU_ENROLLMENT_MANAGEMENT.H Public Interface
//

/**
 * @brief Creates enrollment management module handle.
 * @return ADUC_AGENT_MODULE_HANDLE The created module handle, or NULL on failure.
 */
ADUC_AGENT_MODULE_HANDLE ADUC_Enrollment_Management_Create()
{
    ADUC_AGENT_MODULE_HANDLE interface = NULL;

    ADUC_AGENT_MODULE_INTERFACE* tmp = NULL;

    ADUC_Retriable_Operation_Context* operationContext = CreateAndInitializeEnrollmentRequestOperation();
    if (operationContext == NULL)
    {
        Log_Error("Failed to create enrollment request operation");
        goto done;
    }

    tmp = calloc(1, sizeof(*tmp));
    if (tmp == NULL)
    {
        goto done;
    }

    tmp->getContractInfo = ADUC_Enrollment_Management_GetContractInfo;
    tmp->initializeModule = ADUC_Enrollment_Management_Initialize;
    tmp->deinitializeModule = ADUC_Enrollment_Management_Deinitialize;
    tmp->doWork = ADUC_Enrollment_Management_DoWork;
    tmp->destroy = ADUC_Enrollment_Management_Destroy;

    tmp->moduleData = operationContext;
    operationContext = NULL;

    interface = tmp;
    tmp = NULL;

done:

    TopicMgmtLifecycle_UninitRetriableOperationContext(operationContext);
    free(operationContext);

    free(tmp);

    return interface;
}

/**
 * @brief Destroy the module handle.
 *
 * @param handle The module handle.
 */
void ADUC_Enrollment_Management_Destroy(ADUC_AGENT_MODULE_HANDLE handle)
{
    ADUC_Retriable_Operation_Context* context = OperationContextFromAgentModuleHandle(handle);
    if (context == NULL)
    {
        Log_Error("Failed to get operation context");
        return;
    }

    context->operationDestroyFunc(context);
    free(context);
}

/**
 * @brief Callback should be called when the client receives an enrollment status response message from the Device Update service.
 *  For 'enr_resp' messages, if the Correlation Data matches the 'en,the client should parse the message and update the enrollment state.
 *
 * @param mosq The mosquitto instance making the callback.
 * @param obj The user data provided in mosquitto_new. This is the module state
 * @param msg The message data.
 * @param props The MQTT v5 properties returned with the message.
 *
 * @remark This callback is called by the network thread. Usually by the same thread that calls mosquitto_loop function.
 * IMPORTANT - Do not use blocking functions in this callback.
 */
void OnMessage_enr_resp(
    struct mosquitto* mosq, void* obj, const struct mosquitto_message* msg, const mosquitto_property* props)
{
    bool isEnrolled = false;
    char* scopeId = NULL;

    ADUC_Retriable_Operation_Context* context = (ADUC_Retriable_Operation_Context*)obj;
    ADUC_Enrollment_Request_Operation_Data* enrollmentData = EnrollmentData_FromOperationContext(context);

    if (enrollmentData == NULL)
    {
        Log_Error("Enrollment Data was NULL in operation context");
        goto done;
    }

    json_print_properties(props);

    if (!ADU_are_correlation_ids_matching(props, enrollmentData->enrReqMessageContext.correlationId))
    {
        Log_Info("OnMessage_enr_resp: correlation data mismatch");
        goto done;
    }

    if (msg == NULL || msg->payload == NULL || msg->payloadlen == 0)
    {
        Log_Error("Bad payload. msg:%p, payload:%p, payloadlen:%d", msg, msg->payload, msg->payloadlen);
        goto done;
    }

    if (!ParseAndValidateCommonResponseUserProperties(props, "enr_resp" /* expectedMsgType */, &enrollmentData->respUserProps))
    {
        Log_Error("Fail parse of common user props");
        goto done;
    }

    if (!ParseEnrollmentMessagePayload(msg->payload, &isEnrolled, &scopeId))
    {
        Log_Error("Failed parse of msg payload: %s", (char*)msg->payload);
        goto done;
    }

    if (!Handle_Enrollment_Response(
        enrollmentData,
        isEnrolled,
        scopeId,
        context))
    {
        Log_Error("Failed handling enrollment response.");
        goto done;
    }

done:
    free(scopeId);
}

//
// END - ADU_ENROLLMENT_MANAGEMENT.H Public Interface
//
/////////////////////////////////////////////////////////////////////////////