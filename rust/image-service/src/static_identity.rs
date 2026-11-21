use codexone_config::SingleIdentity;
use codexone_execution::{
    ExecutionError, ExecutionService, Owner, StaticAdmissionRequest, StaticAuthorization,
    StaticIdentity, StaticIdentityConfig,
};
use http::{HeaderMap, HeaderValue, Uri, header};

use crate::{ImageAdmission, ImageDispatch, ServiceError};

/// The provider target and durable scope are derived from the same loaded credential.
/// Share the resulting policy and worker with the rest of the data plane.
pub struct StaticImageTarget {
    owner: Owner,
    base: Uri,
    headers: HeaderMap,
}

impl StaticImageTarget {
    pub fn from_config(
        identity: &SingleIdentity,
        policy_version: String,
        pricing_version: String,
    ) -> Result<(Self, StaticIdentity), ServiceError> {
        let invalid = ServiceError::InvalidConfiguration;
        if identity.managed_keys {
            return Err(invalid);
        }
        let responses = &identity.responses;
        let token = identity
            .read_upstream_token()
            .map_err(|_| ServiceError::InvalidConfiguration)?;
        let base = identity
            .upstream_base_url
            .parse()
            .map_err(|_| ServiceError::InvalidConfiguration)?;
        let policy = StaticIdentity::new(
            StaticIdentityConfig {
                principal: identity
                    .principal
                    .clone()
                    .ok_or(ServiceError::InvalidConfiguration)?,
                key_id: identity
                    .key_id
                    .clone()
                    .ok_or(ServiceError::InvalidConfiguration)?,
                key_sha256: identity
                    .key_sha256
                    .ok_or(ServiceError::InvalidConfiguration)?,
                namespace: identity.namespace.clone(),
                identity: identity.identity.clone(),
                upstream_base_url: identity.upstream_base_url.clone(),
                models: responses
                    .models
                    .iter()
                    .map(|model| model.id.clone())
                    .collect(),
                vision_input: responses
                    .models
                    .iter()
                    .any(|model| model.vision_input == Some(true)),
                image_models: responses
                    .image_generation
                    .iter()
                    .flat_map(|images| images.models.iter().map(|model| model.id.clone()))
                    .collect(),
                policy_version,
                pricing_version,
                reserved_micros: responses.reserved_micros,
            },
            token.as_ref().map(|token| token.as_str()),
        )?;
        let mut headers = HeaderMap::new();
        if let Some(token) = token {
            let mut value = HeaderValue::from_str(&format!("Bearer {}", token.as_str()))
                .map_err(|_| ServiceError::InvalidConfiguration)?;
            value.set_sensitive(true);
            headers.insert(header::AUTHORIZATION, value);
        }
        Ok((
            Self {
                owner: policy.owner().clone(),
                base,
                headers,
            },
            policy,
        ))
    }

    /// Authenticate before collecting the ingress body when the gateway has the headers.
    pub fn authenticate(
        execution: &ExecutionService,
        headers: &HeaderMap,
    ) -> Result<StaticAuthorization, ExecutionError> {
        let values = headers.get_all(header::AUTHORIZATION);
        let mut values = values.iter();
        match (values.next(), values.next()) {
            (Some(value), None) => execution.authenticate_static(&[value
                .to_str()
                .map_err(|_| ExecutionError::Unauthorized)?]),
            _ => Err(ExecutionError::Unauthorized),
        }
    }

    pub(crate) async fn admit(
        &self,
        service: &ExecutionService,
        authorization: &StaticAuthorization,
        request: ImageAdmission,
    ) -> Result<ImageDispatch, ExecutionError> {
        let execution = service
            .admit_static(
                authorization,
                StaticAdmissionRequest {
                    requirements: request.requirements(),
                    attempt: request.attempt,
                    request_id: Some(request.request_id),
                    model: request.model,
                    mode: codexone_execution::Mode::Generation,
                    references: Vec::new(),
                    reasoning_effort: None,
                    service_tier: request.service_tier,
                },
            )
            .await?;
        if execution.admission().owner != self.owner {
            return Err(ExecutionError::InvalidCommand);
        }
        Ok(ImageDispatch {
            execution,
            base: self.base.clone(),
            account_headers: self.headers.clone(),
        })
    }
}
