using Microsoft.Azure.Cosmos;
using Moq;

namespace incidents_service.Tests;

// Shared across IncidentServiceTests and IncidentsControllerTests - both
// GetIncidentsAsync and GetNotifications drive the exact same
// "while (iterator.HasMoreResults) { var page = await iterator.ReadNextAsync(); list.AddRange(page); }"
// pattern against the real Cosmos SDK types, so the mock setup for it only needs to exist once.
internal static class CosmosMockHelpers
{
    // Single-page iterator: HasMoreResults is true until ReadNextAsync has been called once,
    // then false - enough to drive the loop exactly once, matching every real call site in this
    // codebase (none of them paginate across multiple pages).
    public static Mock<FeedIterator<T>> MockFeedIterator<T>(List<T> items)
    {
        var mockFeedResponse = new Mock<FeedResponse<T>>();
        mockFeedResponse.Setup(r => r.GetEnumerator()).Returns(items.GetEnumerator());

        var mockIterator = new Mock<FeedIterator<T>>();
        var hasRead = false;
        mockIterator.Setup(i => i.HasMoreResults).Returns(() => !hasRead);
        mockIterator
            .Setup(i => i.ReadNextAsync(It.IsAny<CancellationToken>()))
            .Callback(() => hasRead = true)
            .ReturnsAsync(mockFeedResponse.Object);

        return mockIterator;
    }

    public static CosmosException NotFoundException() =>
        new("not found", System.Net.HttpStatusCode.NotFound, 0, "", 0);

    public static CosmosException ServiceUnavailableException() =>
        new("service unavailable", System.Net.HttpStatusCode.ServiceUnavailable, 0, "", 0);
}
