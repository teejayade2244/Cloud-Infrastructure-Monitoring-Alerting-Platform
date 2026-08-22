using Microsoft.AspNetCore.Http;
using incidents_service.Middleware;

namespace incidents_service.Tests;

// CreateIncident/GetIncidents/GetIncident/UpdateIncident have no try/catch of their own (only
// GetNotifications does) - a thrown exception from any of them is only ever converted to a 500
// by THIS middleware, at the HTTP pipeline level. A controller-method-level unit test can never
// observe that (there's no pipeline to catch it), so this is the only place that behavior is
// honestly testable without standing up a full integration/functional test host.
public class ErrorHandlingMiddlewareTests
{
    private static HttpContext NewContext()
    {
        var context = new DefaultHttpContext();
        context.Response.Body = new MemoryStream();
        return context;
    }

    [Fact]
    public async Task InvokeAsync_NextSucceeds_PassesThroughUntouched()
    {
        var context = NewContext();
        var middleware = new ErrorHandlingMiddleware(_ => Task.CompletedTask);

        await middleware.InvokeAsync(context);

        Assert.Equal(200, context.Response.StatusCode); // ASP.NET Core's default, never touched
    }

    [Fact]
    public async Task InvokeAsync_NextThrows_Returns500WithJsonErrorBody()
    {
        var context = NewContext();
        var middleware = new ErrorHandlingMiddleware(_ => throw new InvalidOperationException("boom"));

        await middleware.InvokeAsync(context);

        Assert.Equal(500, context.Response.StatusCode);
        Assert.Equal("application/json", context.Response.ContentType);
        context.Response.Body.Seek(0, SeekOrigin.Begin);
        var body = await new StreamReader(context.Response.Body).ReadToEndAsync();
        Assert.Equal("{\"error\": \"Internal server error\"}", body);
    }

    [Fact]
    public async Task InvokeAsync_DoesNotLeakTheOriginalExceptionMessageToTheResponseBody()
    {
        // The response body is a fixed, generic string regardless of what actually went wrong -
        // confirms internal error detail (e.g. a Cosmos connection string, a stack trace) never
        // reaches the client, unlike GetNotifications' own catch block, which does return
        // ex.Message. Deliberately different behavior between the two, both worth pinning down.
        var context = NewContext();
        var middleware = new ErrorHandlingMiddleware(
            _ => throw new InvalidOperationException("cosmos-connection-string=super-secret"));

        await middleware.InvokeAsync(context);

        context.Response.Body.Seek(0, SeekOrigin.Begin);
        var body = await new StreamReader(context.Response.Body).ReadToEndAsync();
        Assert.DoesNotContain("super-secret", body);
    }
}
