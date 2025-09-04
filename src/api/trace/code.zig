/// Status codes
pub const Code = enum {
    /// The default status
    Unset,
    /// The operation has been validated by an Application developer or Operator to have completed successfully
    Ok,
    /// The operation contains an error
    Error,
};
