import pytest
from unittest.mock import AsyncMock, MagicMock, patch
import json
import main

@pytest.mark.asyncio
async def test_persist_price():
    mock_client = MagicMock()
    mock_client.rpc.return_value.execute.return_value = {"data": "success"}
    
    await main.persist_price(mock_client, 1, 25.50)
    
    mock_client.rpc.assert_called_once()
    args = mock_client.rpc.call_args[0]
    assert args[0] == "add_product_and_price"
    assert args[1]["p_price_value"] == 25.50
    assert args[1]["p_establishment_id"] == 1

@pytest.mark.asyncio
async def test_scrape_chedraui_success():
    with patch("httpx.AsyncClient.get", new_callable=AsyncMock) as mock_get:
        mock_response = MagicMock()
        mock_response.status_code = 200
        mock_response.json.return_value = [{
            "items": [{"sellers": [{"commertialOffer": {"Price": 28.00}}]}]
        }]
        mock_get.return_value = mock_response
        
        price = await main.scrape_chedraui()
        assert price == 28.00

@pytest.mark.asyncio
async def test_scrape_chedraui_failure():
    with patch("httpx.AsyncClient.get", new_callable=AsyncMock) as mock_get:
        mock_response = MagicMock()
        mock_response.status_code = 404
        mock_get.return_value = mock_response
        
        price = await main.scrape_chedraui()
        assert price is None

@pytest.mark.asyncio
async def test_scrape_soriana_html_fallback():
    with patch("httpx.AsyncClient.get", new_callable=AsyncMock) as mock_get:
        mock_response = MagicMock()
        mock_response.status_code = 200
        # Simulate JSON decode error to trigger fallback
        mock_response.json.side_effect = json.JSONDecodeError("Expecting value", "", 0)
        mock_response.text = '<html><div class="price"><div class="sales"><span class="value">$30.50</span></div></div></html>'
        mock_get.return_value = mock_response
        
        price = await main.scrape_soriana()
        assert price == 30.50
