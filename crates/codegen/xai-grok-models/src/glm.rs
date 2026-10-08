//! The GLM Coding Plan's endpoints and models.
//!
//! A subscription is bought on z.ai or on bigmodel.cn. The two sites keep separate
//! accounts and keys, and each serves the plan from its own coding endpoint; the
//! general `/api/paas/v4` endpoint does not draw on a plan's quota.
//! The plan has no model list to fetch, so its models are named here.
//! See https://docs.z.ai/devpack/overview.

/// z.ai, for subscriptions bought outside mainland China.
pub const GLM_BASE_URL: &str = "https://api.z.ai/api/coding/paas/v4";
/// bigmodel.cn, for subscriptions bought in mainland China.
pub const GLM_CN_BASE_URL: &str = "https://open.bigmodel.cn/api/coding/paas/v4";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct GlmModel {
    /// The id sent on the wire.
    pub id: &'static str,
    pub name: &'static str,
    pub context_window: u64,
    pub max_output_tokens: u32,
    pub supports_images: bool,
}

/// Every plan tier includes both. Older ids (`glm-5.2`, `glm-4.7`, ...) are routed to one of these by the service.
pub const MODELS: [GlmModel; 2] = [
    GlmModel {
        id: "glm-5.3",
        name: "GLM-5.3",
        context_window: 1_000_000,
        max_output_tokens: 131_072,
        supports_images: false,
    },
    GlmModel {
        id: "glm-5.3-flash",
        name: "GLM-5.3 Flash",
        context_window: 1_000_000,
        max_output_tokens: 131_072,
        supports_images: true,
    },
];

pub fn model(id: &str) -> Option<&'static GlmModel> {
    MODELS.iter().find(|model| model.id == id)
}
