//! `/git-graph`: a full-screen, read-only view of the repository's commit graph.
//!
//! The overlay asks for work through [`Request`]s; the app runs each off the UI thread with
//! [`run`] and hands the [`Response`] back to the overlay, which drops any it no longer wants.

pub mod data;
pub mod layout;
pub mod tui;

use std::path::PathBuf;

pub use data::Scope;

/// Git work the overlay needs done off the UI thread.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Request {
    /// Read the graph for the repository containing `cwd`.
    Load {
        cwd: PathBuf,
        scope: Scope,
        limit: usize,
        /// Echoed back so a superseded load is ignored.
        generation: u64,
    },
    /// Read the paths one commit changed.
    Files {
        root: PathBuf,
        hash: String,
        parents: Vec<String>,
    },
}

#[derive(Debug)]
pub enum Response {
    Loaded {
        generation: u64,
        result: Result<Box<data::GraphData>, String>,
    },
    Files {
        root: PathBuf,
        hash: String,
        result: Result<Vec<data::FileStat>, String>,
    },
}

impl Request {
    /// The response reporting that this request could not run.
    pub fn fail(&self, error: String) -> Response {
        match self {
            Self::Load { generation, .. } => Response::Loaded {
                generation: *generation,
                result: Err(error),
            },
            Self::Files { root, hash, .. } => Response::Files {
                root: root.clone(),
                hash: hash.clone(),
                result: Err(error),
            },
        }
    }
}

/// Runs a request; blocking, so call it from a blocking task.
pub fn run(request: Request) -> Response {
    match request {
        Request::Load {
            cwd,
            scope,
            limit,
            generation,
        } => Response::Loaded {
            generation,
            result: data::load(&cwd, scope, limit).map(Box::new),
        },
        Request::Files {
            root,
            hash,
            parents,
        } => {
            let result = data::load_files(&root, &hash, &parents);
            Response::Files { root, hash, result }
        }
    }
}

#[cfg(test)]
mod integration_tests;
