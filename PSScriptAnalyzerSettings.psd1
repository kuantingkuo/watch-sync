@{
    # Enforce actionable correctness rules without imposing an unrelated style rewrite.
    IncludeRules = @(
        'PSUseApprovedVerbs'
        'PSAvoidEmptyCatchBlock'
        'PSAvoidUsingInvokeExpression'
        'PSAvoidUsingConvertToSecureStringWithPlainText'
        'PSAvoidUsingPlainTextForPassword'
        'PSAvoidUsingUsernameAndPasswordParams'
        'PSAvoidUsingComputerNameHardcoded'
        'PSUseDeclaredVarsMoreThanAssignments'
    )
}
